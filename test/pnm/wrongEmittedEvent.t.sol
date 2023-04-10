// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../../contracts/registry/ENSRegistry.sol";
import "../../contracts/ethregistrar/BaseRegistrarImplementation.sol";
import "../../contracts/ethregistrar/DummyOracle.sol";
import "../../contracts/wrapper/StaticMetadataService.sol";
import "../../contracts/wrapper/IMetadataService.sol";
import "../../contracts/wrapper/NameWrapper.sol";

import {IncompatibleParent, IncorrectTargetOwner, OperationProhibited, Unauthorised} from "../../contracts/wrapper/NameWrapper.sol";
import {CANNOT_UNWRAP, CANNOT_BURN_FUSES, CANNOT_TRANSFER, CANNOT_SET_RESOLVER, CANNOT_SET_TTL, CANNOT_CREATE_SUBDOMAIN, PARENT_CANNOT_CONTROL, CAN_DO_EVERYTHING} from "../../contracts/wrapper/INameWrapper.sol";
import {NameEncoder} from "../../contracts/utils/NameEncoder.sol";
import {ReverseRegistrar} from "../../contracts/reverseRegistrar/ReverseRegistrar.sol";
import {PublicResolver} from "../../contracts/resolvers/PublicResolver.sol";
import {AggregatorInterface, StablePriceOracle} from "../../contracts/ethregistrar/StablePriceOracle.sol";
import {ETHRegistrarController, IETHRegistrarController, IPriceOracle} from "../../contracts/ethregistrar/ETHRegistrarController.sol";

import {PTest} from "lib/narya-contracts/PTest.sol";
import {VmSafe} from "lib/narya-contracts/lib/forge-std/src/Vm.sol";
import {console} from "lib/narya-contracts/lib/forge-std/src/console.sol";

contract wrongEmittedEvent is PTest {
    NameWrapper public wrapper;
    ENSRegistry public registry;
    StaticMetadataService public metadata;
    IETHRegistrarController public controller;
    BaseRegistrarImplementation public baseRegistrar;
    ReverseRegistrar public reverseRegistrar;
    PublicResolver public publicResolver;

    address owner;
    address user;

    address MOCK_RESOLVER = 0x4976fb03C32e5B8cfe2b6cCB31c09Ba78EBaBa41;
    address EMPTY_ADDRESS = 0x0000000000000000000000000000000000000000;
    bytes32 ROOT_NODE =
        0x0000000000000000000000000000000000000000000000000000000000000000;
    uint256 CONTRACT_INIT_TIMESTAMP = 90 days;

    struct LogInfo {
        string name;
        uint256 cost;
        uint256 eventCost;
    }

    LogInfo[] pnmLogs;

    event NameRenewed(
        string name,
        bytes32 indexed label,
        uint256 cost,
        uint256 expires
    );

    function setUp() public {
        owner = makeAddr("OWNER");
        user = makeAddr("USER");

        vm.startPrank(owner);

        // warp beyond expire + grace period
        vm.warp(CONTRACT_INIT_TIMESTAMP + 1);

        // registry
        registry = new ENSRegistry();

        // base registrar
        baseRegistrar = new BaseRegistrarImplementation(
            registry,
            namehash("eth")
        );

        baseRegistrar.addController(owner);

        // metadata
        metadata = new StaticMetadataService("https://ens.domains");
        IMetadataService ms = IMetadataService(address(metadata));

        // reverse registrar
        reverseRegistrar = new ReverseRegistrar(registry);

        registry.setSubnodeOwner(ROOT_NODE, labelhash("reverse"), owner);
        registry.setSubnodeOwner(
            namehash("reverse"),
            labelhash("addr"),
            address(reverseRegistrar)
        );

        publicResolver = new PublicResolver(
            registry,
            INameWrapper(address(0)),
            address(0),
            address(reverseRegistrar)
        );

        reverseRegistrar.setDefaultResolver(address(publicResolver));

        // name wrapper
        wrapper = new NameWrapper(registry, baseRegistrar, ms);

        registry.setSubnodeOwner(
            ROOT_NODE,
            labelhash("eth"),
            address(baseRegistrar)
        );
        registry.setSubnodeOwner(ROOT_NODE, labelhash("xyz"), user);

        baseRegistrar.addController(address(wrapper));
        baseRegistrar.addController(owner);
        wrapper.setController(owner, true);

        baseRegistrar.setApprovalForAll(address(wrapper), true);

        // setup oracles
        DummyOracle dummyOracle = new DummyOracle(100000000);
        AggregatorInterface aggregator = AggregatorInterface(
            address(dummyOracle)
        );

        uint256[] memory rentPrices = new uint256[](5);
        uint8[5] memory _prices = [0, 0, 4, 2, 1];
        for (uint256 i = 0; i < _prices.length; i++) {
            rentPrices[i] = _prices[i];
        }

        StablePriceOracle priceOracle = new StablePriceOracle(
            aggregator,
            rentPrices
        );

        ETHRegistrarController ensReg = new ETHRegistrarController(
            baseRegistrar,
            priceOracle,
            0, // min commitment age
            86400, // max commitment age
            reverseRegistrar,
            wrapper,
            registry
        );

        controller = IETHRegistrarController(ensReg);

        wrapper.setController(address(controller), true);

        vm.stopPrank();

        vm.deal(user, 1 ether);
    }

    function testRegisterAndRenew() public {
        actionRegisterAndRenew();
        invariantRenameEvent();
    }

    function actionRegisterAndRenew() public {
        vm.startPrank(user);

        string memory name = "xyz";

        IPriceOracle.Price memory price = controller.rentPrice(name, 28 days);
        // console.log("price base", price.base);
        // console.log("premium", price.premium);

        bytes[] memory data;
        bytes32 secret = bytes32("012345678901234567890123456789ab");

        controller.commit(
            controller.makeCommitment(
                name,
                owner,
                28 days,
                secret,
                address(0),
                data,
                false,
                0
            )
        );

        controller.register{value: price.base + price.premium}(
            name,
            owner,
            28 days,
            secret,
            address(0),
            data,
            false,
            0
        );

        uint256 balanceBefore = user.balance;

        vm.recordLogs();
        controller.renew{value: price.base + price.premium + 1000}(
            name,
            28 days
        );

        uint256 balanceAfter = user.balance;

        require(balanceAfter == balanceBefore - price.base - price.premium);

        // extract event arguments and save log
        uint256 eventPrice = 0;
        VmSafe.Log[] memory entries = vm.getRecordedLogs();
        for (uint i = 0; i < entries.length; ++i) {
            if (entries[i].topics[0] == NameRenewed.selector) {
                if ((entries[i].topics[1]) == keccak256(bytes(name))) {
                    uint256[] memory args = splitBytes(entries[i].data);
                    eventPrice = args[1];
                }
            }
        }

        // console.log("node", uint256(keccak256(bytes(name))));
        // console.log("price", price.base+price.premium);
        // console.log("price2", price.base+price.premium+1000);

        pnmLogs.push(LogInfo(name, price.base + price.premium, eventPrice));

        vm.stopPrank();
    }

    function splitBytes(bytes memory data) internal returns (uint256[] memory) {
        uint256 words_cnt = data.length / 32;
        uint256[] memory words = new uint256[](words_cnt);

        for (uint i = 0; i < words_cnt; ++i) {
            for (uint j = 0; j < 32; ++j) {
                words[i] |= (uint256(uint8(data[i * 0x20 + j])) <<
                    ((32 - 1 - j) * 8));
            }
            // console.log("arg", words[i]);
        }

        return words;
    }

    function invariantRenameEvent() public {
        for (uint i = 0; i < pnmLogs.length; ++i) {
            LogInfo memory log = pnmLogs[i];
            require(
                log.cost == log.eventCost,
                "Wrong cost in NameRenewed event"
            );
        }

        delete pnmLogs;
    }

    // utility methods

    function namehash(string memory name) private pure returns (bytes32) {
        (, bytes32 testnameNamehash) = NameEncoder.dnsEncodeName(name);
        return testnameNamehash;
    }

    function labelhash(string memory label) private pure returns (bytes32) {
        return keccak256(bytes(label));
    }
}
