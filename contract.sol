// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * DepositVault — BNB / BSC (BEP-20 network)
 *
 * - Each registered user gets a unique deposit address (UserProxy via CREATE2)
 * - Owner funds a BNB gas pool; new users get a small BNB drip automatically
 * - All BNB sent to any proxy flows to one vaultWallet
 * - No ERC-20 / token logic — native BNB only
 *
 * Compile : Solidity ^0.8.20
 * Network : Binance Smart Chain (BSC) mainnet / testnet
 * Deploy  : Hardhat, Foundry, or Remix (select "BNB Chain" environment)
 */

abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Not owner");
        _;
    }

    function owner() public view returns (address) { return _owner; }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

abstract contract ReentrancyGuard {
    uint256 private _status = 1;

    modifier nonReentrant() {
        require(_status == 1, "Reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}

interface IDepositVault {
    function receiveFromProxy(address user) external payable;
}

// ─────────────────────────────────────────────
//  UserProxy — one deployed per user via CREATE2
//  User sends BNB to this address → auto-forwarded to vaultWallet
// ─────────────────────────────────────────────
contract UserProxy {
    address public immutable vault;
    address public immutable user;

    constructor(address _vault, address _user) {
        vault = _vault;
        user  = _user;
    }

    receive() external payable {
        IDepositVault(vault).receiveFromProxy{value: msg.value}(user);
    }

    fallback() external payable {
        if (msg.value > 0) {
            IDepositVault(vault).receiveFromProxy{value: msg.value}(user);
        }
    }
}

// ─────────────────────────────────────────────
//  DepositVault — main contract
// ─────────────────────────────────────────────
contract DepositVault is Ownable, ReentrancyGuard, IDepositVault {

    address public vaultWallet;
    uint256 public gasDripAmount;

    mapping(address => address)  public proxyOf;
    mapping(address => bool)     public registered;
    mapping(address => uint256)  public totalDeposited;
    mapping(address => bool)     public gasDripped;

    address[] private _userList;

    event UserRegistered    (address indexed user, address proxy);
    event GasDripped        (address indexed user, uint256 amount);
    event BNBDeposited      (address indexed user, uint256 amount);
    event VaultWalletChanged(address newWallet);
    event GasDripChanged    (uint256 newAmount);
    event GasPoolFunded     (address indexed funder, uint256 amount);
    event EmergencyWithdraw (uint256 amount);

    /**
     * @param _vaultWallet   BSC address that receives all user BNB deposits
     * @param _gasDripAmount BNB in wei to drip per user e.g. 2000000000000000 = 0.002 BNB
     */
    constructor(address _vaultWallet, uint256 _gasDripAmount) {
        require(_vaultWallet != address(0), "Invalid vault wallet");
        vaultWallet   = _vaultWallet;
        gasDripAmount = _gasDripAmount;
    }

    // Owner sends BNB here to fund the gas pool
    receive() external payable {
        emit GasPoolFunded(msg.sender, msg.value);
    }

    // ══════════════════════════════════════════
    //  OWNER FUNCTIONS
    // ══════════════════════════════════════════

    function registerUser(address user) external onlyOwner {
        _register(user);
    }

    function registerUsersBatch(address[] calldata _users) external onlyOwner {
        for (uint256 i; i < _users.length; i++) {
            if (_users[i] == address(0) || registered[_users[i]]) continue;
            _register(_users[i]);
        }
    }

    function dripGas(address user) external onlyOwner nonReentrant {
        require(registered[user], "Not registered");
        require(!gasDripped[user], "Already dripped");
        _dripGas(user);
    }

    function dripGasBatch(address[] calldata _users) external onlyOwner nonReentrant {
        for (uint256 i; i < _users.length; i++) {
            if (!registered[_users[i]]) continue;
            if (gasDripped[_users[i]]) continue;
            if (address(this).balance < gasDripAmount) break;
            _dripGas(_users[i]);
        }
    }

    function reDripGas(address user) external onlyOwner nonReentrant {
        require(registered[user], "Not registered");
        require(address(this).balance >= gasDripAmount, "Gas pool empty");
        _dripGas(user);
    }

    function setVaultWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Invalid address");
        vaultWallet = newWallet;
        emit VaultWalletChanged(newWallet);
    }

    function setGasDripAmount(uint256 amount) external onlyOwner {
        gasDripAmount = amount;
        emit GasDripChanged(amount);
    }

    function withdrawGasPool() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        require(bal > 0, "Nothing to withdraw");
        _sendBNB(vaultWallet, bal);
        emit EmergencyWithdraw(bal);
    }

    // ══════════════════════════════════════════
    //  USER FUNCTIONS
    // ══════════════════════════════════════════

    /**
     * @notice User calls this to deposit BNB directly.
     *         Funds instantly forward to vaultWallet.
     */
    function depositBNB() external payable nonReentrant {
        require(registered[msg.sender], "Not registered");
        require(msg.value > 0, "Send BNB");
        _recordAndForward(msg.sender, msg.value);
    }

    fallback() external payable nonReentrant {
        if (msg.value > 0 && registered[msg.sender]) {
            _recordAndForward(msg.sender, msg.value);
        }
    }

    // ══════════════════════════════════════════
    //  PROXY CALLBACK
    // ══════════════════════════════════════════

    /**
     * @notice Called automatically by UserProxy when it receives BNB.
     */
    function receiveFromProxy(address user)
        external
        payable
        override
        nonReentrant
    {
        require(proxyOf[user] == msg.sender, "Unknown proxy");
        require(msg.value > 0, "No BNB");
        _recordAndForward(user, msg.value);
    }

    // ══════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ══════════════════════════════════════════

    /**
     * @notice Get a user's deposit address (proxy) — show this in your dApp.
     *         Works even before the proxy is deployed.
     */
    function getProxyAddress(address user) external view returns (address proxy) {
        bytes32 salt    = keccak256(abi.encodePacked(user));
        bytes memory bc = abi.encodePacked(
            type(UserProxy).creationCode,
            abi.encode(address(this), user)
        );
        proxy = address(uint160(uint256(
            keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bc)))
        )));
    }

    function getUserCount() external view returns (uint256) {
        return _userList.length;
    }

    function getUserAt(uint256 index) external view returns (address) {
        return _userList[index];
    }

    function gasPoolBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getAllUsers() external view returns (address[] memory) {
        return _userList;
    }

    // ══════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════

    function _register(address user) internal {
        require(user != address(0), "Zero address");
        require(!registered[user], "Already registered");

        bytes32 salt    = keccak256(abi.encodePacked(user));
        UserProxy proxy = new UserProxy{salt: salt}(address(this), user);

        proxyOf[user]    = address(proxy);
        registered[user] = true;
        _userList.push(user);

        emit UserRegistered(user, address(proxy));

        if (gasDripAmount > 0 && address(this).balance >= gasDripAmount) {
            _dripGas(user);
        }
    }

    function _dripGas(address user) internal {
        gasDripped[user] = true;
        _sendBNB(user, gasDripAmount);
        emit GasDripped(user, gasDripAmount);
    }

    function _recordAndForward(address user, uint256 amount) internal {
        totalDeposited[user] += amount;
        emit BNBDeposited(user, amount);
        _sendBNB(vaultWallet, amount);
    }

    function _sendBNB(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "BNB transfer failed");
    }
}