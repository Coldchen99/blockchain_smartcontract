//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "IERC20.sol";

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}


pragma solidity ^0.8.0;
/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _setOwner(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _setOwner(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _setOwner(newOwner);
    }

    function _setOwner(address newOwner) private {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}



contract htlcBridge is Ownable {

    event NewPortal(address indexed Sender, uint Amount, address Contract);
    event DestinationPortalOpened(address indexed Sender, address indexed Receiver, uint Amount);
    event DestinationTransferFinalized(address indexed Sender);

    struct Transfer {
        bytes32 commitment;     //merkle tree root hash
        address sender;         //used to generate commitment (leaf)
        address receiver;       //used to generate commitment (leaf)
        address tokenContract;  //used to generate commitment (leaf)
        uint amount;            //used to generate commitment (leaf)
        bytes32 hashLock;
        uint timeLock;
    }

    mapping(address=>Transfer) _transfersOut;
    mapping(address=>Transfer) _transfersIn;
    mapping(address=>bool) _hasActiveTransferOut;
    mapping(address=>address) public contractToContract;

    modifier noActiveTransferOut {
        require(_hasActiveTransferOut[msg.sender] == false, "Error: Ongoing Transfer, wait until it either completes or expires");
        _;
    }

    function initPortal(bytes32 _commitment, bytes32 _hashLock, address _tokenContract, address _receiver, uint _amount) external noActiveTransferOut{
        IERC20 tokenContract = IERC20(_tokenContract);
        require(tokenContract.allowance(msg.sender, address(this)) >= _amount, "Error: Insuficient allowance");
        _hasActiveTransferOut[msg.sender] = true;
        _transfersOut[msg.sender] = Transfer(_commitment, msg.sender, _receiver, _tokenContract, _amount, _hashLock, block.timestamp + 1 hours);
        tokenContract.transferFrom(msg.sender, address(this), _amount);
        emit NewPortal(msg.sender, _amount, _tokenContract);
    }

    function portalFromOtherChain(
        bytes32 _commitment, 
        bytes32 _hashLock, 
        uint _timeLock, 
        address _tokenContract, 
        address _sender, 
        address _receiver, 
        uint _amount) 
    external {
        //require(getCommitment(_sender, _receiver, _tokenContract, _amount) == _commitment, "Error: Transfer data doesn't match commitment");
        require(contractToContract[_tokenContract] != address(0x0), "Error: Token contract doesn't have a match in this chain");
        _transfersIn[_receiver] = Transfer(_commitment, _sender, _receiver, contractToContract[_tokenContract], _amount, _hashLock, _timeLock);
        emit DestinationPortalOpened(_sender, _receiver, _amount);

    }

    function finalizeInterPortalTransferDest(address _receiver, string memory _secretKey) public { 
        Transfer memory transfer = _transfersIn[_receiver];
        IERC20 tokenContract = IERC20(contractToContract[transfer.tokenContract]);
        require(hashThis(abi.encode(_secretKey)) == transfer.hashLock, "Error: hash lock does not match");
        require(block.timestamp <= transfer.timeLock, "Error: transfer wasn't finalized within time");
        require(tokenContract.balanceOf(address(this)) >= transfer.amount, "Error: not enough liquidity to bridge funds");
        tokenContract.transfer(_receiver, transfer.amount);
        emit DestinationTransferFinalized(transfer.sender);
    }

    function finalizeInterPortalTransferOrigin(address _sender) public { 
        _hasActiveTransferOut[_sender] = false;
    }

    function withdrawFunds() public {
        require(_hasActiveTransferOut[msg.sender], "Error: sender does not have a pending transfer");
        Transfer memory transfer = _transfersOut[msg.sender];
        require(transfer.timeLock < block.timestamp, "Error: ongoing transfer");
        _hasActiveTransferOut[msg.sender] = false;
        IERC20 tokenContract = IERC20(transfer.tokenContract);
        tokenContract.transfer(msg.sender, transfer.amount);
    }

    function setPairContract(address _source, address _local) public onlyOwner {
        contractToContract[_source] = _local;
    }

    function getTransferOut(address _sender) external view
    returns(
        bytes32,
        address,
        address,
        address,
        uint,
        uint,
        bytes32
    ){
        require(_hasActiveTransferOut[_sender], "Error: There aren't any ongoing transfer for the sender");
        Transfer memory transfer = _transfersOut[_sender];
        return (transfer.commitment, _sender, transfer.receiver, transfer.tokenContract, transfer.amount, transfer.timeLock, transfer.hashLock);
    }

    function getCommitment(address _sender, address _receiver, address _tokenContract, uint _amount) public pure returns(bytes32) {
        return hashThis(abi.encodePacked(
                    hashThis(abi.encodePacked(hashThis(abi.encodePacked(_sender)),hashThis(abi.encodePacked(_receiver)))),
                    hashThis(abi.encodePacked(hashThis(abi.encodePacked(_tokenContract)),hashThis(abi.encodePacked(_amount))))
        ));
    }
    
    function hashThis(bytes memory _input) public pure returns(bytes32){
        return sha256(_input);
    }

    function encode(address _x) public pure returns(bytes memory) {
        return abi.encodePacked(_x);
    }
}