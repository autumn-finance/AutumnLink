// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "./AutumnLink.sol";
import "./interfaces/ENSInterface.sol";
import "./interfaces/AutumnTokenInterface.sol";
import "./interfaces/AutumnLinkRequestInterface.sol";
import "./interfaces/PointerInterface.sol";
import { ENSResolver as ENSResolver_AutumnLink } from "./vendor/ENSResolver.sol";

/**
 * @title The AutumnLinkClient contract
 * @notice Contract writers can inherit this contract in order to create requests for the
 * AutumnLink network
 */
contract AutumnLinkClient {
  using AutumnLink for AutumnLink.Request;

  uint256 constant internal ATM = 10**18;
  uint256 constant private AMOUNT_OVERRIDE = 0;
  address constant private SENDER_OVERRIDE = address(0);
  uint256 constant private ARGS_VERSION = 1;
  bytes32 constant private ENS_TOKEN_SUBNAME = keccak256("atm");
  bytes32 constant private ENS_ORACLE_SUBNAME = keccak256("oracle");
  address constant private ATM_TOKEN_POINTER = 0x3a751b78f38e70119520A4305834bdF6299aDbcB;

  ENSInterface private ens;
  bytes32 private ensNode;
  AutumnTokenInterface private autumn;
  AutumnLinkRequestInterface private oracle;
  uint256 private requestCount = 1;
  mapping(bytes32 => address) private pendingRequests;

  event AutumnLinkRequested(bytes32 indexed id);
  event AutumnLinkFulfilled(bytes32 indexed id);
  event AutumnLinkCancelled(bytes32 indexed id);

  /**
   * @notice Creates a request that can hold additional parameters
   * @param _specId The Job Specification ID that the request will be created for
   * @param _callbackAddress The callback address that the response will be sent to
   * @param _callbackFunctionSignature The callback function signature to use for the callback address
   * @return A AutumnLink Request struct in memory
   */
  function buildAutumnLinkRequest(
    bytes32 _specId,
    address _callbackAddress,
    bytes4 _callbackFunctionSignature
  ) internal pure returns (AutumnLink.Request memory) {
    AutumnLink.Request memory req;
    return req.initialize(_specId, _callbackAddress, _callbackFunctionSignature);
  }

  /**
   * @notice Creates a AutumnLink request to the stored oracle address
   * @dev Calls `autumnLinkRequestTo` with the stored oracle address
   * @param _req The initialized AutumnLink Request
   * @param _payment The amount of ATM to send for the request
   * @return requestId The request ID
   */
  function sendAutumnLinkRequest(AutumnLink.Request memory _req, uint256 _payment)
    internal
    returns (bytes32)
  {
    return sendAutumnLinkRequestTo(address(oracle), _req, _payment);
  }

  /**
   * @notice Creates a AutumnLink request to the specified oracle address
   * @dev Generates and stores a request ID, increments the local nonce, and uses `transferAndCall` to
   * send ATM which creates a request on the target oracle contract.
   * Emits AutumnLinkRequested event.
   * @param _oracle The address of the oracle for the request
   * @param _req The initialized AutumnLink Request
   * @param _payment The amount of ATM to send for the request
   * @return requestId The request ID
   */
  function sendAutumnLinkRequestTo(address _oracle, AutumnLink.Request memory _req, uint256 _payment)
    internal
    returns (bytes32 requestId)
  {
    requestId = keccak256(abi.encodePacked(this, requestCount));
    _req.nonce = requestCount;
    pendingRequests[requestId] = _oracle;
    emit AutumnLinkRequested(requestId);
    require(autumn.transferAndCall(_oracle, _payment, encodeRequest(_req)), "unable to transferAndCall to oracle");
    requestCount += 1;

    return requestId;
  }

  /**
   * @notice Allows a request to be cancelled if it has not been fulfilled
   * @dev Requires keeping track of the expiration value emitted from the oracle contract.
   * Deletes the request from the `pendingRequests` mapping.
   * Emits AutumnLinkCancelled event.
   * @param _requestId The request ID
   * @param _payment The amount of ATM sent for the request
   * @param _callbackFunc The callback function specified for the request
   * @param _expiration The time of the expiration for the request
   */
  function cancelAutumnLinkRequest(
    bytes32 _requestId,
    uint256 _payment,
    bytes4 _callbackFunc,
    uint256 _expiration
  )
    internal
  {
    AutumnLinkRequestInterface requested = AutumnLinkRequestInterface(pendingRequests[_requestId]);
    delete pendingRequests[_requestId];
    emit AutumnLinkCancelled(_requestId);
    requested.cancelOracleRequest(_requestId, _payment, _callbackFunc, _expiration);
  }

  /**
   * @notice Sets the stored oracle address
   * @param _oracle The address of the oracle contract
   */
  function setAutumnLinkOracle(address _oracle) internal {
    oracle = AutumnLinkRequestInterface(_oracle);
  }

  /**
   * @notice Sets the ATM token address
   * @param _atm The address of the ATM token contract
   */
  function setAutumnLinkToken(address _atm) internal {
    autumn = AutumnTokenInterface(_atm);
  }

  /**
   * @notice Sets the AutumnLink token address for the public
   * network as given by the Pointer contract
   */
  function setPublicAutumnLinkToken() internal {
    setAutumnLinkToken(PointerInterface(ATM_TOKEN_POINTER).getAddress());
  }

  /**
   * @notice Retrieves the stored address of the ATM token
   * @return The address of the ATM token
   */
  function autumnLinkTokenAddress()
    internal
    view
    returns (address)
  {
    return address(autumn);
  }

  /**
   * @notice Retrieves the stored address of the oracle contract
   * @return The address of the oracle contract
   */
  function autumnLinkOracleAddress()
    internal
    view
    returns (address)
  {
    return address(oracle);
  }

  /**
   * @notice Allows for a request which was created on another contract to be fulfilled
   * on this contract
   * @param _oracle The address of the oracle contract that will fulfill the request
   * @param _requestId The request ID used for the response
   */
  function addAutumnLinkExternalRequest(address _oracle, bytes32 _requestId)
    internal
    notPendingRequest(_requestId)
  {
    pendingRequests[_requestId] = _oracle;
  }

  /**
   * @notice Sets the stored oracle and ATM token contracts with the addresses resolved by ENS
   * @dev Accounts for subnodes having different resolvers
   * @param _ens The address of the ENS contract
   * @param _node The ENS node hash
   */
  function useAutumnLinkWithENS(address _ens, bytes32 _node)
    internal
  {
    ens = ENSInterface(_ens);
    ensNode = _node;
    bytes32 linkSubnode = keccak256(abi.encodePacked(ensNode, ENS_TOKEN_SUBNAME));
    ENSResolver_AutumnLink resolver = ENSResolver_AutumnLink(ens.resolver(linkSubnode));
    setAutumnLinkToken(resolver.addr(linkSubnode));
    updateAutumnLinkOracleWithENS();
  }

  /**
   * @notice Sets the stored oracle contract with the address resolved by ENS
   * @dev This may be called on its own as long as `useAutumnLinkWithENS` has been called previously
   */
  function updateAutumnLinkOracleWithENS()
    internal
  {
    bytes32 oracleSubnode = keccak256(abi.encodePacked(ensNode, ENS_ORACLE_SUBNAME));
    ENSResolver_AutumnLink resolver = ENSResolver_AutumnLink(ens.resolver(oracleSubnode));
    setAutumnLinkOracle(resolver.addr(oracleSubnode));
  }

  /**
   * @notice Encodes the request to be sent to the oracle contract
   * @dev The AutumnLink node expects values to be in order for the request to be picked up. Order of types
   * will be validated in the oracle contract.
   * @param _req The initialized AutumnLink Request
   * @return The bytes payload for the `transferAndCall` method
   */
  function encodeRequest(AutumnLink.Request memory _req)
    private
    view
    returns (bytes memory)
  {
    return abi.encodeWithSelector(
      oracle.oracleRequest.selector,
      SENDER_OVERRIDE, // Sender value - overridden by onTokenTransfer by the requesting contract's address
      AMOUNT_OVERRIDE, // Amount value - overridden by onTokenTransfer by the actual amount of ATM sent
      _req.id,
      _req.callbackAddress,
      _req.callbackFunctionId,
      _req.nonce,
      ARGS_VERSION,
      _req.buf.buf);
  }

  /**
   * @notice Ensures that the fulfillment is valid for this contract
   * @dev Use if the contract developer prefers methods instead of modifiers for validation
   * @param _requestId The request ID for fulfillment
   */
  function validateAutumnLinkCallback(bytes32 _requestId)
    internal
    recordAutumnLinkFulfillment(_requestId)
    // solhint-disable-next-line no-empty-blocks
  {}

  /**
   * @dev Reverts if the sender is not the oracle of the request.
   * Emits AutumnLinkFulfilled event.
   * @param _requestId The request ID for fulfillment
   */
  modifier recordAutumnLinkFulfillment(bytes32 _requestId) {
    require(msg.sender == pendingRequests[_requestId],
            "Source must be the oracle of the request");
    delete pendingRequests[_requestId];
    emit AutumnLinkFulfilled(_requestId);
    _;
  }

  /**
   * @dev Reverts if the request is already pending
   * @param _requestId The request ID for fulfillment
   */
  modifier notPendingRequest(bytes32 _requestId) {
    require(pendingRequests[_requestId] == address(0), "Request is already pending");
    _;
  }
}
