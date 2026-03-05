// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BlindAuction
 * @dev Subasta ciega usando commit-reveal scheme (criptografía de compromiso hash)
 *
 * FLUJO:
 * 1. COMMIT  (0 → commitDeadline):        los postores envían hash(cantidad, secreto, dirección) + depósito
 * 2. REVEAL  (commitDeadline → revealDeadline): revelan cantidad y secreto real
 * 3. FINALIZAR (tras revealDeadline):      el owner llama a finalize()
 * 4. PAGO    (tras finalize):              el ganador llama a payWinningBid() antes del paymentDeadline
 * 5. COBRO   (tras pago o deadline):       el owner cobra o confisca depósito
 *
 * CÓMO GENERAR EL HASH (en Remix directamente):
 *   Llama a hashBid(amount, secret, address) antes de hacer commit.
 *
 * CÓMO GENERAR EL HASH (en JS / ethers.js):
 *   const hash = ethers.solidityPackedKeccak256(
 *     ["uint256", "bytes32", "address"],
 *     [bidAmount, ethers.encodeBytes32String("mi_secreto"), signerAddress]
 *   );
 */
contract BlindAuction {

    // ─── Estructuras ────────────────────────────────────────────────
    struct Bidder {
        bytes32 commitment;   // hash del compromiso
        uint256 deposit;      // ETH depositado como garantía
        uint256 revealedBid;  // cantidad revelada (0 si aún no ha revelado)
        bool    hasRevealed;  // true tras reveal válido
        bool    hasWithdrawn; // true tras retirar depósito
    }

    // ─── Estado ─────────────────────────────────────────────────────
    address public owner;
    uint256 public commitDeadline;    // timestamp fin fase commit
    uint256 public revealDeadline;    // timestamp fin fase reveal
    uint256 public minDeposit;        // depósito mínimo obligatorio en wei
    uint256 public paymentDeadline;   // plazo para que el ganador pague
    uint256 public paymentDuration;   // duración del plazo de pago en segundos

    mapping(address => Bidder) public bidders;
    address[] public bidderList;

    address public winner;
    uint256 public winningBid;
    bool    public finalized;
    bool    public winnerPaid;

    // ─── Eventos ────────────────────────────────────────────────────
    event CommitReceived(address indexed bidder, uint256 deposit);
    event BidRevealed(address indexed bidder, uint256 amount);
    event AuctionFinalized(address indexed winner, uint256 amount);
    event DepositWithdrawn(address indexed bidder, uint256 amount);
    event WinnerPaymentReceived(address indexed winner, uint256 total);
    event DepositConfiscated(address indexed winner, uint256 penalty);

    // ─── Modificadores ──────────────────────────────────────────────
    modifier onlyOwner()     { require(msg.sender == owner, "Solo el owner"); _; }
    modifier inCommitPhase() { require(block.timestamp < commitDeadline, "Fase commit cerrada"); _; }
    modifier inRevealPhase() {
        require(block.timestamp >= commitDeadline, "Fase reveal no iniciada");
        require(block.timestamp <  revealDeadline, "Fase reveal cerrada");
        _;
    }
    modifier afterReveal()   { require(block.timestamp >= revealDeadline, "Reveal no terminado"); _; }
    modifier notFinalized()  { require(!finalized, "Ya finalizado"); _; }

    // ─── Constructor ────────────────────────────────────────────────
    /**
     * @param _commitDuration   Segundos que dura la fase de commit   (ej: 300 = 5 min)
     * @param _revealDuration   Segundos que dura la fase de reveal   (ej: 300 = 5 min)
     * @param _minDeposit       Depósito mínimo en wei                (ej: 10000000000000000 = 0.01 ETH)
     * @param _paymentDuration  Segundos que tiene el ganador para pagar (ej: 86400 = 24h)
     */
    constructor(
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _minDeposit,
        uint256 _paymentDuration
    ) {
        owner           = msg.sender;
        commitDeadline  = block.timestamp + _commitDuration;
        revealDeadline  = commitDeadline  + _revealDuration;
        minDeposit      = _minDeposit;
        paymentDuration = _paymentDuration;
    }

    // ─── FASE 1: COMMIT ─────────────────────────────────────────────
    /**
     * @dev El postor envía su compromiso hash + depósito ETH.
     *      El hash debe generarse FUERA de la cadena para máxima privacidad.
     * @param _commitment  keccak256(abi.encodePacked(bidAmount, secret, msg.sender))
     */
    function commit(bytes32 _commitment) external payable inCommitPhase {
        require(msg.value >= minDeposit,                      "Deposito insuficiente");
        require(bidders[msg.sender].commitment == bytes32(0), "Ya has hecho commit");

        bidders[msg.sender] = Bidder({
            commitment:   _commitment,
            deposit:      msg.value,
            revealedBid:  0,
            hasRevealed:  false,
            hasWithdrawn: false
        });
        bidderList.push(msg.sender);

        emit CommitReceived(msg.sender, msg.value);
    }

    // ─── FASE 2: REVEAL ─────────────────────────────────────────────
    /**
     * @dev El postor revela su puja real. El contrato verifica que coincida con el hash.
     * @param _amount  Cantidad pujada en wei
     * @param _secret  Secreto usado al generar el hash
     */
    function reveal(uint256 _amount, bytes32 _secret) external inRevealPhase {
        Bidder storage b = bidders[msg.sender];

        require(b.commitment != bytes32(0), "No has hecho commit");
        require(!b.hasRevealed,             "Ya revelaste");

        // Verificación criptográfica del compromiso
        bytes32 expectedHash = keccak256(abi.encodePacked(_amount, _secret, msg.sender));
        require(b.commitment == expectedHash, "Hash invalido: cantidad o secreto incorrectos");

        b.hasRevealed = true;
        b.revealedBid = _amount;

        emit BidRevealed(msg.sender, _amount);
    }

    // ─── FASE 3: FINALIZAR ──────────────────────────────────────────
    /**
     * @dev Determina al ganador entre todos los que revelaron correctamente.
     *      Solo el owner puede llamar esta función tras el periodo de reveal.
     *      Abre el plazo de pago para el ganador.
     */
    function finalize() external onlyOwner afterReveal notFinalized {
        uint256 highestBid    = 0;
        address highestBidder = address(0);

        for (uint256 i = 0; i < bidderList.length; i++) {
            address addr = bidderList[i];
            Bidder storage b = bidders[addr];

            if (b.hasRevealed && b.revealedBid > highestBid) {
                highestBid    = b.revealedBid;
                highestBidder = addr;
            }
        }

        winner          = highestBidder;
        winningBid      = highestBid;
        finalized       = true;
        paymentDeadline = block.timestamp + paymentDuration;

        emit AuctionFinalized(winner, winningBid);
    }

    // ─── FASE 4: PAGO DEL GANADOR ───────────────────────────────────
    /**
     * @dev El ganador paga la diferencia entre su puja real y el depósito ya entregado.
     *      Debe llamar a esta función antes de que expire paymentDeadline.
     *      msg.value debe ser exactamente (winningBid - deposit).
     */
    function payWinningBid() external payable {
        require(finalized,                           "No finalizado");
        require(msg.sender == winner,                "Solo el ganador");
        require(!winnerPaid,                         "Ya pagaste");
        require(block.timestamp <= paymentDeadline,  "Plazo de pago expirado");

        uint256 depositAlreadyPaid = bidders[winner].deposit;

        // Calcula cuánto falta por pagar
        uint256 remainingAmount = winningBid > depositAlreadyPaid
            ? winningBid - depositAlreadyPaid
            : 0;

        require(msg.value == remainingAmount, "Cantidad incorrecta");

        winnerPaid = true;
        bidders[winner].hasWithdrawn = true;

        // El owner recibe el total: depósito + diferencia = puja completa
        uint256 total = depositAlreadyPaid + msg.value;
        (bool success, ) = payable(owner).call{value: total}("");
        require(success, "Transferencia fallida");

        emit WinnerPaymentReceived(winner, total);
    }

    // ─── FASE 5a: CONFISCAR DEPÓSITO (si el ganador no pagó) ────────
    /**
     * @dev Si el ganador no pagó antes del deadline, el owner confisca su depósito
     *      como penalización. La subasta queda desierta.
     */
    function confiscateDeposit() external onlyOwner {
        require(finalized,                          "No finalizado");
        require(!winnerPaid,                        "El ganador ya pago");
        require(block.timestamp > paymentDeadline,  "Plazo aun activo");

        uint256 penalty = bidders[winner].deposit;
        bidders[winner].hasWithdrawn = true;

        (bool success, ) = payable(owner).call{value: penalty}("");
        require(success, "Transferencia fallida");

        emit DepositConfiscated(winner, penalty);
    }

    // ─── FASE 5b: RETIRAR DEPÓSITO (perdedores) ─────────────────────
    /**
     * @dev Los perdedores recuperan su depósito tras la finalización.
     *      El ganador NO puede retirar su depósito por esta vía.
     */
    function withdrawDeposit() external {
        require(finalized,            "Subasta no finalizada");
        require(msg.sender != winner, "El ganador no puede retirar por aqui");

        Bidder storage b = bidders[msg.sender];
        require(b.deposit > 0,    "Sin deposito");
        require(!b.hasWithdrawn,  "Ya retirado");

        b.hasWithdrawn = true;
        uint256 amount = b.deposit;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transferencia fallida");

        emit DepositWithdrawn(msg.sender, amount);
    }

    // ─── UTILIDADES ─────────────────────────────────────────────────

    /**
     * @dev Helper para generar el hash directamente desde Remix (para pruebas).
     *      En producción, generar el hash OFF-CHAIN para privacidad total.
     */
    function hashBid(uint256 _amount, bytes32 _secret, address _bidder)
        public pure returns (bytes32)
    {
        return keccak256(abi.encodePacked(_amount, _secret, _bidder));
    }

    /// @dev Cuántos postores han participado
    function getBidderCount() external view returns (uint256) {
        return bidderList.length;
    }

    /// @dev Tiempo restante en cada fase (en segundos)
    function timeLeft() external view returns (
        uint256 commitRemaining,
        uint256 revealRemaining,
        uint256 paymentRemaining
    ) {
        commitRemaining  = block.timestamp < commitDeadline
            ? commitDeadline - block.timestamp : 0;
        revealRemaining  = block.timestamp < revealDeadline
            ? revealDeadline - block.timestamp : 0;
        paymentRemaining = (finalized && block.timestamp < paymentDeadline)
            ? paymentDeadline - block.timestamp : 0;
    }
}
