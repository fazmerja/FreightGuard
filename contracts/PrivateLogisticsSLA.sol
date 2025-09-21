// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Официальная библиотека Zama */
import {FHE, ebool, euint64, euint256, externalEuint64, externalEuint256} from "@fhevm/solidity/lib/FHE.sol";

/* Конфиг Sepolia — адреса KMS/Oracle/ACL */
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title PrivateLogisticsSLA
 * @notice Приватная логистика: клиенты шифруют маршрут/груз/дедлайн.
 *         Контракт отмечает доставку и публикует ebool «SLA выполнен?»
 *         без раскрытия деталей.
 */
contract PrivateLogisticsSLA is SepoliaConfig {
    /* ─────────────── Версия / события ─────────────── */

    function version() external pure returns (string memory) {
        return "PrivateLogisticsSLA/1.2.0-sepolia";
    }

    event ShipmentCreated(
        uint256 indexed shipmentId,
        address indexed shipper,
        address indexed carrier,
        address consignee
    );

    event MetaIngested(
        uint256 indexed shipmentId,
        bytes32 cargoTagHandle,
        bytes32 routeTagHandle,
        bytes32 deadlineHandle
    );

    event DeliveryMarked(uint256 indexed shipmentId, bytes32 deliveredAtHandle, bytes32 slaOkHandle);

    event ViewerGranted(uint256 indexed shipmentId, address indexed viewer);

    /* ─────────────── Модель данных ─────────────── */

    struct Shipment {
        address shipper;
        address carrier;
        address consignee;
        // Конфиденциальные поля (заполняются второй транзакцией):
        euint256 cargoTag; // зашифр. идентификатор/коммит груза
        euint256 routeTag; // зашифр. коммит маршрута
        euint64 deadlineTs; // зашифр. дедлайн SLA (UNIX sec)
        bool haveMeta; // мета импортирована
        // Результаты:
        bool deliveredFlag; // факт доставки (публичный bool)
        euint64 deliveredAt; // зашифр. время доставки
        ebool slaOk; // публично дешифруемый ebool
        bool exists;
    }

    mapping(uint256 => Shipment) private _byId;

    /* ─────────────── Модификаторы ─────────────── */

    modifier onlyParty(uint256 shipmentId) {
        Shipment storage s = _byId[shipmentId];
        require(s.exists, "Shipment not found");
        require(msg.sender == s.shipper || msg.sender == s.carrier || msg.sender == s.consignee, "Not authorized");
        _;
    }

    /* ─────────────── 1/2: создание каркаса отправления ─────────────── */

    function createShipment(uint256 shipmentId, address carrier, address consignee) external {
        require(!_byId[shipmentId].exists, "Shipment exists");
        require(carrier != address(0) && consignee != address(0), "Zero address");

        Shipment storage s = _byId[shipmentId];
        s.exists = true;
        s.shipper = msg.sender;
        s.carrier = carrier;
        s.consignee = consignee;
        // haveMeta=false; deliveredFlag=false по умолчанию

        emit ShipmentCreated(shipmentId, msg.sender, carrier, consignee);
    }

    /* ─────────────── 2/2: импорт зашифрованной меты ───────────────
       Берём raw bytes32-хэндлы (меньше аргументов и локалок) и proof.
       Оборачиваем их в externalE* прямо внутри вызовов.                */

    function ingestEncryptedMeta(
        uint256 shipmentId,
        bytes32 cargoTagExtRaw,
        bytes calldata cargoProof,
        bytes32 routeTagExtRaw,
        bytes calldata routeProof,
        bytes32 deadlineTsExtRaw,
        bytes calldata deadlineProof
    ) external onlyParty(shipmentId) {
        Shipment storage s = _byId[shipmentId];
        require(!s.haveMeta, "Meta already ingested");
        require(
            cargoTagExtRaw != bytes32(0) && routeTagExtRaw != bytes32(0) && deadlineTsExtRaw != bytes32(0),
            "Empty handle"
        );
        require(cargoProof.length > 0 && routeProof.length > 0 && deadlineProof.length > 0, "Empty proof");

        // external -> e* (внутри проверяется аттестация)
        s.cargoTag = FHE.fromExternal(externalEuint256.wrap(cargoTagExtRaw), cargoProof);
        s.routeTag = FHE.fromExternal(externalEuint256.wrap(routeTagExtRaw), routeProof);
        s.deadlineTs = FHE.fromExternal(externalEuint64.wrap(deadlineTsExtRaw), deadlineProof);

        // Контракту — право дальнейшего использования (stateful)
        FHE.allowThis(s.cargoTag);
        FHE.allowThis(s.routeTag);
        FHE.allowThis(s.deadlineTs);

        // ACL для участников (для userDecrypt на фронте)
        FHE.allow(s.cargoTag, s.shipper);
        FHE.allow(s.routeTag, s.shipper);
        FHE.allow(s.deadlineTs, s.shipper);

        FHE.allow(s.cargoTag, s.carrier);
        FHE.allow(s.routeTag, s.carrier);
        FHE.allow(s.deadlineTs, s.carrier);

        FHE.allow(s.cargoTag, s.consignee);
        FHE.allow(s.routeTag, s.consignee);
        FHE.allow(s.deadlineTs, s.consignee);

        s.haveMeta = true;

        emit MetaIngested(
            shipmentId,
            FHE.toBytes32(s.cargoTag),
            FHE.toBytes32(s.routeTag),
            FHE.toBytes32(s.deadlineTs)
        );
    }

    /* ─────────────── Отметить доставку ─────────────── */

    function markDelivered(uint256 shipmentId) external onlyParty(shipmentId) {
        Shipment storage s = _byId[shipmentId];
        require(s.haveMeta, "Meta not ingested");
        require(!s.deliveredFlag, "Already delivered");

        // Поднимаем timestamp в euint64
        euint64 deliveredAtCt = FHE.asEuint64(uint64(block.timestamp));
        // Сравнение с зашифрованным дедлайном: deliveredAt <= deadline ?
        ebool onTime = FHE.le(deliveredAtCt, s.deadlineTs);

        // ACL
        FHE.allowThis(deliveredAtCt);
        FHE.allowThis(onTime);

        FHE.allow(deliveredAtCt, s.shipper);
        FHE.allow(deliveredAtCt, s.carrier);
        FHE.allow(deliveredAtCt, s.consignee);

        FHE.allow(onTime, s.shipper);
        FHE.allow(onTime, s.carrier);
        FHE.allow(onTime, s.consignee);

        // Публичная дешифровка только статуса SLA
        FHE.makePubliclyDecryptable(onTime);

        s.deliveredFlag = true;
        s.deliveredAt = deliveredAtCt;
        s.slaOk = onTime;

        emit DeliveryMarked(shipmentId, FHE.toBytes32(deliveredAtCt), FHE.toBytes32(onTime));
    }

    /* ─────────────── ACL: добавить зрителя ─────────────── */

    function grantViewer(uint256 shipmentId, address viewer) external onlyParty(shipmentId) {
        require(viewer != address(0), "Zero viewer");
        Shipment storage s = _byId[shipmentId];

        if (s.haveMeta) {
            FHE.allow(s.cargoTag, viewer);
            FHE.allow(s.routeTag, viewer);
            FHE.allow(s.deadlineTs, viewer);
        }
        if (s.deliveredFlag) {
            FHE.allow(s.deliveredAt, viewer);
            FHE.allow(s.slaOk, viewer);
        }

        emit ViewerGranted(shipmentId, viewer);
    }

    /* ─────────────── View API (без FHE-вычислений) ─────────────── */

    function getParticipants(
        uint256 shipmentId
    ) external view returns (address shipper, address carrier, address consignee, bool delivered, bool haveMeta) {
        Shipment storage s = _byId[shipmentId];
        require(s.exists, "Shipment not found");
        return (s.shipper, s.carrier, s.consignee, s.deliveredFlag, s.haveMeta);
    }

    function getEncryptedMetaHandles(
        uint256 shipmentId
    ) external view returns (bytes32 cargoTagH, bytes32 routeTagH, bytes32 deadlineTsH) {
        Shipment storage s = _byId[shipmentId];
        require(s.exists, "Shipment not found");
        if (!s.haveMeta) return (bytes32(0), bytes32(0), bytes32(0));
        return (FHE.toBytes32(s.cargoTag), FHE.toBytes32(s.routeTag), FHE.toBytes32(s.deadlineTs));
    }

    function getResultHandles(
        uint256 shipmentId
    ) external view returns (bool delivered, bytes32 deliveredAtH, bytes32 slaOkH) {
        Shipment storage s = _byId[shipmentId];
        require(s.exists, "Shipment not found");
        if (!s.deliveredFlag) {
            return (false, bytes32(0), bytes32(0));
        }
        return (true, FHE.toBytes32(s.deliveredAt), FHE.toBytes32(s.slaOk));
    }
}
