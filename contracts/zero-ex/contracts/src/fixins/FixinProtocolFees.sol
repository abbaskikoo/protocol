/*

  Copyright 2020 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.6.5;
pragma experimental ABIEncoderV2;

import "@0x/contracts-erc20/contracts/src/v06/IEtherTokenV06.sol";
import "../external/FeeCollector.sol";
import "../features/libs/LibTokenSpender.sol";
import "../vendor/v3/IStaking.sol";


/// @dev Helpers for collecting protocol fees.
abstract contract FixinProtocolFees {
    /// @dev The protocol fee multiplier.
    uint32 public immutable PROTOCOL_FEE_MULTIPLIER;
    /// @dev Hash of the fee collector init code.
    bytes32 private immutable FEE_COLLECTOR_INIT_CODE_HASH;
    /// @dev The WETH token contract.
    IEtherTokenV06 private immutable WETH;
    /// @dev The staking contract.
    IStaking private immutable STAKING;

    constructor(
        IEtherTokenV06 weth,
        IStaking staking,
        uint32 protocolFeeMultiplier
    )
        internal
    {
        FEE_COLLECTOR_INIT_CODE_HASH = keccak256(type(FeeCollector).creationCode);
        WETH = weth;
        STAKING = staking;
        PROTOCOL_FEE_MULTIPLIER = protocolFeeMultiplier;
    }

    /// @dev   Collect the specified protocol fee in either WETH or ETH. If
    ///        msg.value is non-zero, the fee will be paid in ETH. Otherwise,
    ///        this function attempts to transfer the fee in WETH. Either way,
    ///        The fee is stored in a per-pool fee collector contract.
    /// @param poolId The pool ID for which a fee is being collected.
    /// @param payer The address paying for WETH protocol fees.
    /// @return ethProtocolFeePaid How much protocol fee was collected in ETH.
    /// @return wethProtocolFeePaid How much protocol fee was collected in WETH.
    function _collectProtocolFee(
        bytes32 poolId,
        address payer
    )
        internal
        returns (uint256 ethProtocolFeePaid, uint256 wethProtocolFeePaid)
    {
        FeeCollector feeCollector = _getFeeCollector(poolId);
        uint256 protocolFeePaid = _getSingleProtocolFee();

        if (msg.value < protocolFeePaid) {
            // WETH
            LibTokenSpender.spendERC20Tokens(
                WETH,
                payer,
                address(feeCollector),
                protocolFeePaid
            );
            wethProtocolFeePaid = protocolFeePaid;
        } else {
            // ETH
            (bool success,) = address(feeCollector).call{value: protocolFeePaid}("");
            require(success, "FixinProtocolFees/ETHER_TRANSFER_FALIED");
            ethProtocolFeePaid = protocolFeePaid;
        }
    }

    /// @dev Transfer fees for a given pool to the staking contract.
    /// @param poolId Identifies the pool whose fees are being paid.
    function _transferFeesForPool(bytes32 poolId)
        internal
    {
        FeeCollector feeCollector = _getFeeCollector(poolId);

        uint256 codeSize;
        assembly {
            codeSize := extcodesize(feeCollector)
        }

        if (codeSize == 0) {
            // Create and initialize the contract if necessary.
            new FeeCollector{salt: bytes32(poolId)}();
            feeCollector.initialize(WETH, STAKING, poolId);
        }

        if (address(feeCollector).balance > 1) {
            feeCollector.convertToWeth(WETH);
        }

        uint256 bal = WETH.balanceOf(address(feeCollector));
        if (bal > 1) {
            // Leave 1 wei behind to avoid high SSTORE cost of zero-->non-zero.
            STAKING.payProtocolFee(
                address(feeCollector),
                address(feeCollector),
                bal - 1);
        }
    }

    /// @dev Compute the CREATE2 address for a fee collector.
    /// @param poolId The fee collector's pool ID.
    function _getFeeCollector(bytes32 poolId)
        internal
        view
        returns (FeeCollector)
    {
        // Compute the CREATE2 address for the fee collector.
        address payable addr = address(uint256(keccak256(abi.encodePacked(
            byte(0xff),
            address(this),
            poolId, // pool ID is salt
            FEE_COLLECTOR_INIT_CODE_HASH
        ))));
        return FeeCollector(addr);
    }

    /// @dev Get the cost of a single protocol fee.
    /// @return protocolFeeAmount The protocol fee amount, in ETH/WETH.
    function _getSingleProtocolFee()
        internal
        view
        returns (uint256 protocolFeeAmount)
    {
        return uint256(PROTOCOL_FEE_MULTIPLIER) * tx.gasprice;
    }
}
