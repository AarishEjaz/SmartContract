// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DepositForwarder
 * @dev Each user gets a unique ChildForwarder contract address.
 *      Any BNB sent to it is instantly forwarded to the master wallet.
 *      Master wallet address is never exposed to users.
 */

// ─── Child Forwarder (one deployed per user) ──────────────────────────────────
contract ChildForwarder {
    address payable public masterWallet;
    address public factory;

    constructor(address payable _masterWallet) {
        masterWallet = _masterWallet;
        factory = msg.sender;
    }

    /**
     * @dev Called when BNB is sent directly to this address
     *      Instantly forwards everything to master wallet
     */
    receive() external payable {
        (bool success, ) = masterWallet.call{value: msg.value}("");
        require(success, "Forward failed");
    }

    /**
     * @dev Manual flush — in case any BNB is stuck
     *      Only factory (owner) can call this
     */
    function flush() external {
        require(msg.sender == factory, "Not authorized");
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = masterWallet.call{value: balance}("");
            require(success, "Flush failed");
        }
    }
}

// ─── Factory Contract (deployed once by you) ──────────────────────────────────
contract DepositForwarderFactory {

    address payable public masterWallet;
    address public owner;

    // user wallet address => their unique deposit contract address
    mapping(address => address) public userForwarder;

    // all forwarders ever created
    address[] public allForwarders;

    event ForwarderCreated(address indexed user, address forwarder);
    event MasterWalletUpdated(address newMaster);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address payable _masterWallet) {
        owner = msg.sender;
        masterWallet = _masterWallet;
    }

    /**
     * @dev Creates a unique deposit address for a user
     *      Called by your backend (owner wallet) when user registers
     */
    function createForwarder(address userAddress) external onlyOwner returns (address) {
        require(userForwarder[userAddress] == address(0), "Forwarder already exists");

        ChildForwarder forwarder = new ChildForwarder(masterWallet);
        userForwarder[userAddress] = address(forwarder);
        allForwarders.push(address(forwarder));

        emit ForwarderCreated(userAddress, address(forwarder));
        return address(forwarder);
    }

    /**
     * @dev Get a user's deposit address
     */
    function getForwarder(address userAddress) external view returns (address) {
        return userForwarder[userAddress];
    }

    /**
     * @dev Emergency: flush a specific forwarder manually
     */
    function flushForwarder(address forwarderAddress) external onlyOwner {
        ChildForwarder(payable(forwarderAddress)).flush();
    }

    /**
     * @dev Update master wallet if needed (only owner)
     */
    function updateMasterWallet(address payable newMaster) external onlyOwner {
        require(newMaster != address(0), "Invalid address");
        masterWallet = newMaster;
        emit MasterWalletUpdated(newMaster);
    }

    /**
     * @dev Transfer ownership
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }

    /**
     * @dev Total number of forwarders created
     */
    function totalForwarders() external view returns (uint256) {
        return allForwarders.length;
    }
}

// with changed conditions
