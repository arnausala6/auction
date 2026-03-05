// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BlindAuction
 * @notice Prototipo minimo de subasta a sobre cerrado (sealed-bid) con commit-reveal.
 *
 * Flujo:
 * 1) Commit phase:
 *    - Cada postor envia un hash de su puja: keccak256(abi.encode(bidAmount, secret))
 *    - Tambien envia ETH (msg.value) como deposito/garantia.
 * 2) Reveal phase:
 *    - Cada postor revela bidAmount y secret.
 *    - El contrato recalcula el hash y verifica que coincida con el commit.
 * 3) Finalizacion:
 *    - Se determina el mayor bid valido.
 *    - El ganador no puede retirar (su deposito queda para el owner).
 *    - Los no ganadores pueden retirar su deposito.
 */
contract BlindAuction {
    address public immutable owner;

    // Tiempo limite para commits y reveals.
    uint256 public immutable commitDeadline;
    uint256 public immutable revealDeadline;

    // Estado final de la subasta.
    bool public finalized;
    address public highestBidder;
    uint256 public highestBid;

    struct Bidder {
        bytes32 commitHash;   // Hash enviado en commit phase.
        uint256 deposit;      // ETH enviado con commitBid.
        bool revealed;        // Si ya llamo revealBid.
        bool withdrawn;       // Si ya retiro fondos.
        uint256 revealedBid;  // Bid revelada (solo si fue valida).
        bool validReveal;     // reveal valido (hash correcto y deposito suficiente).
    }

    mapping(address => Bidder) public bidders;

    event BidCommitted(address indexed bidder, bytes32 commitHash, uint256 deposit);
    event BidRevealed(address indexed bidder, uint256 bidAmount, bool valid);
    event AuctionFinalized(address indexed winner, uint256 winningBid);
    event Withdrawn(address indexed bidder, uint256 amount);

    /**
     * @param commitDuration Duracion (segundos) de la fase de commit.
     * @param revealDuration Duracion (segundos) de la fase de reveal.
     */
    constructor(uint256 commitDuration, uint256 revealDuration) {
        require(commitDuration > 0, "commitDuration debe ser > 0");
        require(revealDuration > 0, "revealDuration debe ser > 0");

        owner = msg.sender;
        commitDeadline = block.timestamp + commitDuration;
        revealDeadline = commitDeadline + revealDuration;
    }

    /**
     * @notice Envia el compromiso (hash) de la puja junto con deposito en ETH.
     * @dev Solo se permite una vez por direccion para mantener el prototipo simple.
     */
    function commitBid(bytes32 commitHash) external payable {
        require(block.timestamp < commitDeadline, "Commit phase terminada");
        require(commitHash != bytes32(0), "commitHash invalido");
        require(msg.value > 0, "Debes enviar deposito");

        Bidder storage b = bidders[msg.sender];
        require(b.commitHash == bytes32(0), "Ya hiciste commit");

        b.commitHash = commitHash;
        b.deposit = msg.value;

        emit BidCommitted(msg.sender, commitHash, msg.value);
    }

    /**
     * @notice Revela la puja y secreto.
     * @dev Verifica que keccak256(abi.encode(bidAmount, secret)) coincida con el commit previo.
     *      Solo cuenta como puja valida si el deposito cubre bidAmount.
     */
    function revealBid(uint256 bidAmount, string memory secret) external {
        require(block.timestamp >= commitDeadline, "Reveal phase no iniciada");
        require(block.timestamp < revealDeadline, "Reveal phase terminada");

        Bidder storage b = bidders[msg.sender];
        require(b.commitHash != bytes32(0), "No tienes commit");
        require(!b.revealed, "Ya revelaste");

        bytes32 expected = keccak256(abi.encode(bidAmount, secret));
        bool valid = (expected == b.commitHash) && (b.deposit >= bidAmount);

        b.revealed = true;

        if (valid) {
            b.validReveal = true;
            b.revealedBid = bidAmount;

            if (bidAmount > highestBid) {
                highestBid = bidAmount;
                highestBidder = msg.sender;
            }
        }

        emit BidRevealed(msg.sender, bidAmount, valid);
    }

    /**
     * @notice Cierra la subasta y envia al owner la puja ganadora (si existe).
     * @dev Puede llamarla cualquiera una vez terminada la fase de reveal.
     */
    function finalizeAuction() external {
        require(block.timestamp >= revealDeadline, "Aun en reveal phase");
        require(!finalized, "Subasta ya finalizada");

        finalized = true;

        if (highestBidder != address(0) && highestBid > 0) {
            // Transferimos el valor ganador al owner.
            // El resto del deposito del ganador quedara disponible para retiro.
            (bool ok, ) = payable(owner).call{value: highestBid}("");
            require(ok, "Transfer al owner fallo");
        }

        emit AuctionFinalized(highestBidder, highestBid);
    }

    /**
     * @notice Permite retirar deposito a no ganadores y excedente del ganador.
     * @dev Solo funciona despues de finalizeAuction para simplificar el flujo.
     */
    function withdraw() external {
        require(finalized, "Subasta no finalizada");

        Bidder storage b = bidders[msg.sender];
        require(!b.withdrawn, "Ya retiraste");

        uint256 amount = 0;

        if (msg.sender == highestBidder) {
            // El ganador solo retira el excedente: deposito - highestBid.
            require(b.deposit >= highestBid, "Estado invalido de deposito");
            amount = b.deposit - highestBid;
        } else {
            // No ganadores retiran todo su deposito.
            amount = b.deposit;
        }

        b.withdrawn = true;
        b.deposit = 0;

        if (amount > 0) {
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            require(ok, "Retiro fallo");
        }

        emit Withdrawn(msg.sender, amount);
    }
}
