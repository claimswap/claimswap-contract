pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin-upgrades-4.8.1/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgrades-4.8.1/contracts/access/OwnableUpgradeable.sol";
import {ClaimswapV2Pair} from "./ClaimswapV2Pair.sol";
import {IDiamondCut} from "./interfaces/IDiamondCut.sol";
import { ICommon } from "./interfaces/ICommon.sol";

contract V2Factory is Initializable, OwnableUpgradeable {
    address diamondCutFacet;
    address stableSwap2PoolPairInitAddress;

    mapping(bytes32 => address) pairs;
    address[] public allPairs;
    IDiamondCut.FacetCut[] public ss2poolFacetCuts;

    /// event
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairLength, uint256 swapType);

    function initialize(address diamondCutFacet_) initializer public {
        diamondCutFacet = diamondCutFacet_;
        __Ownable_init();
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function getAllPairs() external view returns (address[] memory) {
        return allPairs;
    }

    function getPair(address[] memory tokens) public view returns (address) {
        // tokens must be sorted;
        require(tokens.length > 1, "ClaimswapV2Factory: INVALID_TOKENS_LENGTH");
        bytes memory concatenatedAddresses = new bytes(0);
        for (uint i = 0; i < tokens.length; i++) {
            bytes20 addressBytes = bytes20(tokens[i]);
            concatenatedAddresses = abi.encodePacked(concatenatedAddresses, addressBytes);
        }
        bytes32 salt = keccak256(concatenatedAddresses);
        return pairs[salt];
    }

    function sortToken(
        address tokenA,
        address tokenB
    ) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, "ClaimswapV2Factory: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ClaimswapV2Factory: ZERO_ADDRESS");
    }

    // 2Pool
    function createStableSwap2Pool(
        address tokenA,
        address tokenB,
        uint256 fee_,
        uint256 adminFee_,
        uint256 A_
    ) external onlyOwner {
        // 0. validation and sort
        (address token0, address token1) = sortToken(tokenA, tokenB);

        // 1. Deploy Diamond
        bytes memory bytecode = type(ClaimswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        address payable claimswapV2PairContract;
        assembly {
            claimswapV2PairContract := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        pairs[salt] = claimswapV2PairContract;
        allPairs.push(claimswapV2PairContract);

        // 2. init Diamond 
        ClaimswapV2Pair(claimswapV2PairContract).initialize(owner(), diamondCutFacet);

        // 3. init facets and init data
        IDiamondCut(claimswapV2PairContract).diamondCut(ss2poolFacetCuts, stableSwap2PoolPairInitAddress, abi.encodeWithSignature("init(address,address,uint256,uint256,uint256)", token0, token1, fee_, adminFee_, A_));

        emit PairCreated(token0, token1, claimswapV2PairContract, allPairs.length, uint256(ICommon.SwapType.StableSwap));
    }

    // ADMIN FUNCTION
    function addStableSwap2PoolFacetCut(IDiamondCut.FacetCut memory newFacetCut) external onlyOwner {
        ss2poolFacetCuts.push(newFacetCut);
    }

    function addStableSwap2PoolFacetCuts(IDiamondCut.FacetCut[] memory newFacetCuts) external onlyOwner {
        for (uint256 i = 0; i < newFacetCuts.length; i++) {
            ss2poolFacetCuts.push(newFacetCuts[i]);
        }
    }

    function setStableSwap2PoolPairInitAddress(address stableSwap2PoolPairInitAddress_) external onlyOwner {
        stableSwap2PoolPairInitAddress = stableSwap2PoolPairInitAddress_;
    }
}
