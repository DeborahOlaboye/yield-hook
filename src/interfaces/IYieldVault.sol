// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal ERC-4626-compatible vault interface for yield-bearing assets
interface IYieldVault {
    /// @notice Deposit `assets` into the vault, minting `shares` to `receiver`
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Redeem `shares` from the vault, sending underlying `assets` to `receiver`
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Preview how many assets `shares` would redeem to
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice ERC-20 balanceOf (shares)
    function balanceOf(address owner) external view returns (uint256);

    /// @notice Underlying ERC-20 asset address
    function asset() external view returns (address);
}
