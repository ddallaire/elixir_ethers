// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract Logger {
    event Log(bytes data) anonymous;

    fallback() external payable {
        emit Log(msg.data);
    }
}
