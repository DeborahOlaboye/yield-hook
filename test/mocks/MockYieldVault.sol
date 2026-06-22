// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IYieldVault} from "../../src/interfaces/IYieldVault.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice A minimal ERC-4626-like vault mock that supports simulated yield.
///         Yield is added by calling simulateYield(), which mints extra tokens into
///         the vault without issuing new shares — increasing convertToAssets.
contract MockYieldVault is IYieldVault {
    MockERC20 public immutable underlyingToken;

    uint256 public totalShares;
    uint256 public totalAssets;

    mapping(address => uint256) public override balanceOf;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Redeem(address indexed caller, address indexed receiver, uint256 shares, uint256 assets);

    constructor(MockERC20 _token) {
        underlyingToken = _token;
    }

    function asset() external view override returns (address) {
        return address(underlyingToken);
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        underlyingToken.transferFrom(msg.sender, address(this), assets);

        shares = totalShares == 0 ? assets : (assets * totalShares) / totalAssets;
        totalShares += shares;
        totalAssets += assets;
        balanceOf[receiver] += shares;

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        override
        returns (uint256 assets)
    {
        require(balanceOf[owner] >= shares, "insufficient shares");
        assets = (shares * totalAssets) / totalShares;

        balanceOf[owner] -= shares;
        totalShares -= shares;
        totalAssets -= assets;

        underlyingToken.transfer(receiver, assets);

        emit Redeem(msg.sender, receiver, shares, assets);
    }

    function convertToAssets(uint256 shares) external view override returns (uint256) {
        if (totalShares == 0) return shares;
        return (shares * totalAssets) / totalShares;
    }

    /// @notice Simulate external yield accruing in the vault (add tokens without new shares)
    function simulateYield(uint256 yieldAmount) external {
        underlyingToken.mint(address(this), yieldAmount);
        totalAssets += yieldAmount;
    }
}
