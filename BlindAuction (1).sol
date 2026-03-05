// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BlindAuction
 * @dev Subasta ciega con commit-reveal, KYC por firma criptográfica, precio mínimo = fianza,
 *      ranking con fallbacks configurables y penalización por no revelar.
 *
 * ═══════════════════════════════════════════════════════════════════
 * FLUJO COMPLETO
 * ═══════════════════════════════════════════════════════════════════
 *
 * [OFF-CHAIN] Owner verifica identidad del usuario y firma su dirección:
 *     signature = ownerWallet.signMessage(keccak256(userAddress))
 *     → Owner envía la signature al usuario
 *
 * 1. COMMIT  (0 → commitDeadline)
 *     - Usuario llama a commit(hash, signature) + depósito ETH
 *     - El contrato verifica que la signature viene del owner (KYC)
 *     - Solo se guarda el hash de la puja, nunca la cantidad real
 *
 * 2. REVEAL  (commitDeadline → revealDeadline)
 *     - Usuario llama a reveal(amount, secret)
 *     - El contrato recalcula el hash y verifica que coincide
 *     - Si no revela o miente → pierde la fianza (va al owner)
 *
 * 3. FINALIZAR (tras revealDeadline)
 *     - Owner llama a finalize()
 *     - Se construye el ranking ordenado (solo pujas >= minDeposit)
 *     - Se abre el plazo de pago para el primer ganador
 *
 * 4. PAGO (tras finalize → paymentDeadline)
 *     - Ganador actual llama a payWinningBid() con la diferencia (puja - depósito)
 *     - Si pujó exactamente el mínimo, msg.value = 0
 *
 * 5. FALLBACK (si el ganador no paga)
 *     - Owner llama a confiscateAndAdvance()
 *     - Se confisca el depósito del incumplidor
 *     - El siguiente postor del ranking pasa a ser ganador con plazo fresco
 *     - Si se supera maxFallbacks o no hay más postores → subasta desierta
 *
 * 6. CIERRE
 *     - Perdedores que revelaron       → withdrawDeposit()
 *     - Fianzas de no-reveladores      → collectUnrevealedDeposits() (owner)
 *
 * ═══════════════════════════════════════════════════════════════════
 * PARÁMETROS DEL CONSTRUCTOR
 * ═══════════════════════════════════════════════════════════════════
 *  _commitDuration   Segundos de la fase commit            (ej: 300   = 5 min)
 *  _revealDuration   Segundos de la fase reveal            (ej: 300   = 5 min)
 *  _minDeposit       Fianza mínima = precio mínimo en wei  (ej: 10000000000000000 = 0.01 ETH)
 *  _paymentDuration  Segundos para pagar tras ganar        (ej: 86400 = 24h)
 *  _maxFallbacks     Máximo de fallbacks antes de desierta (ej: 3)
 *  _maxBidders       Máximo de postores permitidos         (ej: 20)
 *
 * ═══════════════════════════════════════════════════════════════════
 * CÓMO GENERAR LA FIRMA KYC (owner, off-chain en ethers.js)
 * ═══════════════════════════════════════════════════════════════════
 *  const signature = await ownerWallet.signMessage(
 *      ethers.getBytes(ethers.keccak256(userAddress))
 *  );
 *
 * CÓMO GENERAR EL HASH DE PUJA (en Remix)
 *  Llama a hashBid(amount, secret, tuAddress) → hash listo para commit()
 */
contract BlindAuction {

    // ─── Estructuras ────────────────────────────────────────────────
    struct Bidder {
        bytes32 commitment;   // hash del compromiso de puja
        uint256 deposit;      // ETH depositado como garantía
        uint256 revealedBid;  // cantidad revelada (0 si aún no ha revelado)
        bool    hasRevealed;  // true tras reveal válido
        bool    hasWithdrawn; // true tras retirar depósito o ser confiscado
    }

    // ─── Estado ─────────────────────────────────────────────────────
    address public owner;
    uint256 public commitDeadline;   // timestamp fin fase commit
    uint256 public revealDeadline;   // timestamp fin fase reveal
    uint256 public minDeposit;       // fianza mínima = precio mínimo de puja (wei)
    uint256 public paymentDuration;  // segundos que tiene el ganador para pagar
    uint256 public paymentDeadline;  // timestamp límite de pago del ganador actual
    uint256 public maxFallbacks;     // máximo de fallbacks permitidos
    uint256 public maxBidders;       // máximo de postores permitidos (limita coste de gas)

    mapping(address => Bidder) public bidders;
    address[] public bidderList;

    // Ranking ordenado de mayor a menor puja (se construye en finalize)
    address[] public rankedBidders;
    uint256   public currentWinnerIndex; // índice del ganador actual en rankedBidders
    uint256   public fallbackCount;      // cuántos fallbacks han ocurrido

    bool public finalized;
    bool public auctionSuccessful; // true si alguien completó el pago
    bool public auctionDeserted;   // true si se agotaron los fallbacks

    // ─── Eventos ────────────────────────────────────────────────────
    event CommitReceived(address indexed bidder, uint256 deposit);
    event BidRevealed(address indexed bidder, uint256 amount);
    event AuctionFinalized(address indexed firstWinner, uint256 amount);
    event NewWinnerAssigned(address indexed winner, uint256 amount, uint256 fallbackNumber);
    event WinnerPaymentReceived(address indexed winner, uint256 total);
    event DepositConfiscated(address indexed bidder, uint256 penalty);
    event AuctionDeserted();
    event DepositWithdrawn(address indexed bidder, uint256 amount);

    // ─── Modificadores ──────────────────────────────────────────────
    modifier onlyOwner()     { require(msg.sender == owner, "Solo el owner"); _; }
    modifier inCommitPhase() { require(block.timestamp < commitDeadline, "Fase commit cerrada"); _; }
    modifier inRevealPhase() {
        require(block.timestamp >= commitDeadline, "Fase reveal no iniciada");
        require(block.timestamp <  revealDeadline, "Fase reveal cerrada");
        _;
    }
    modifier afterReveal()  { require(block.timestamp >= revealDeadline, "Reveal no terminado"); _; }
    modifier notFinalized() { require(!finalized, "Ya finalizado"); _; }
    modifier isFinalized()  { require(finalized,  "No finalizado"); _; }

    // ─── Constructor ────────────────────────────────────────────────
    constructor(
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _minDeposit,
        uint256 _paymentDuration,
        uint256 _maxFallbacks,
        uint256 _maxBidders
    ) {
        require(_minDeposit > 0,   "Fianza debe ser mayor que cero");
        require(_maxFallbacks > 0, "maxFallbacks debe ser al menos 1");
        require(_maxBidders > 0,   "maxBidders debe ser al menos 1");

        owner           = msg.sender;
        commitDeadline  = block.timestamp + _commitDuration;
        revealDeadline  = commitDeadline  + _revealDuration;
        minDeposit      = _minDeposit;
        paymentDuration = _paymentDuration;
        maxFallbacks    = _maxFallbacks;
        maxBidders      = _maxBidders;
    }

    // ═══════════════════════════════════════════════════════════════
    // FASE 1: COMMIT
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev El postor envía su hash de puja + depósito + firma KYC del owner.
     *      El contrato verifica criptográficamente que el owner aprobó esta dirección.
     *
     * @param _commitment  keccak256(abi.encodePacked(bidAmount, secret, msg.sender))
     * @param _signature   Firma del owner sobre keccak256(msg.sender) — obtenida off-chain
     */
    function commit(bytes32 _commitment, bytes memory _signature)
        external payable inCommitPhase
    {
        require(_verifyKYC(msg.sender, _signature),           "KYC no verificado: contacta al owner");
        require(bidderList.length < maxBidders,               "Subasta llena");
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

    // ═══════════════════════════════════════════════════════════════
    // FASE 2: REVEAL
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev El postor revela su puja real. El contrato recalcula el hash y verifica.
     *      Si el hash no coincide → transacción falla → hasRevealed sigue false → pierde fianza.
     *      Si no llama a reveal() antes del revealDeadline → hasRevealed sigue false → pierde fianza.
     *      Si revealedBid < minDeposit → reveal válido pero no entra en el ranking.
     *
     * @param _amount  Cantidad pujada en wei
     * @param _secret  Secreto usado al generar el hash en commit
     */
    function reveal(uint256 _amount, bytes32 _secret) external inRevealPhase {
        Bidder storage b = bidders[msg.sender];

        require(b.commitment != bytes32(0), "No has hecho commit");
        require(!b.hasRevealed,             "Ya revelaste");

        // Verificación criptográfica del compromiso
        // Si falla: hasRevealed sigue false → no podrá retirar depósito → pierde fianza
        bytes32 expectedHash = keccak256(abi.encodePacked(_amount, _secret, msg.sender));
        require(b.commitment == expectedHash, "Hash invalido: cantidad o secreto incorrectos");

        b.hasRevealed = true;
        b.revealedBid = _amount;

        emit BidRevealed(msg.sender, _amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // FASE 3: FINALIZAR
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Construye el ranking ordenado de mayor a menor puja.
     *      Solo entran postores que revelaron y pujaron >= minDeposit.
     *      Usa bubble sort — seguro hasta maxBidders postores.
     *      Abre el plazo de pago para el primer ganador.
     */
    function finalize() external onlyOwner afterReveal notFinalized {
        // Recopilar postores válidos para el ranking
        for (uint256 i = 0; i < bidderList.length; i++) {
            address addr = bidderList[i];
            if (bidders[addr].hasRevealed && bidders[addr].revealedBid >= minDeposit) {
                rankedBidders.push(addr);
            }
        }

        // Ordenar de mayor a menor puja (bubble sort — O(n²), acotado por maxBidders)
        for (uint256 i = 0; i < rankedBidders.length; i++) {
            for (uint256 j = i + 1; j < rankedBidders.length; j++) {
                if (bidders[rankedBidders[j]].revealedBid > bidders[rankedBidders[i]].revealedBid) {
                    address tmp      = rankedBidders[i];
                    rankedBidders[i] = rankedBidders[j];
                    rankedBidders[j] = tmp;
                }
            }
        }

        finalized          = true;
        currentWinnerIndex = 0;
        fallbackCount      = 0;

        if (rankedBidders.length == 0) {
            // Nadie superó el precio mínimo → subasta desierta
            auctionDeserted = true;
            emit AuctionDeserted();
        } else {
            paymentDeadline = block.timestamp + paymentDuration;
            emit AuctionFinalized(
                rankedBidders[0],
                bidders[rankedBidders[0]].revealedBid
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // FASE 4: PAGO DEL GANADOR ACTUAL
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev El ganador actual paga la diferencia entre su puja y el depósito ya entregado.
     *      msg.value debe ser exactamente (revealedBid - deposit).
     *      Si deposit >= revealedBid (pujó exactamente el mínimo), msg.value = 0.
     */
    function payWinningBid() external payable isFinalized {
        require(!auctionDeserted,                                "Subasta desierta");
        require(!auctionSuccessful,                              "Subasta ya completada");
        require(currentWinnerIndex < rankedBidders.length,       "Sin ganador activo");
        require(msg.sender == rankedBidders[currentWinnerIndex], "No eres el ganador actual");
        require(block.timestamp <= paymentDeadline,              "Plazo de pago expirado");

        address w               = rankedBidders[currentWinnerIndex];
        uint256 depositPaid     = bidders[w].deposit;
        uint256 winningBid      = bidders[w].revealedBid;
        uint256 remainingAmount = winningBid > depositPaid ? winningBid - depositPaid : 0;

        require(msg.value == remainingAmount, "Cantidad incorrecta");

        auctionSuccessful       = true;
        bidders[w].hasWithdrawn = true;

        uint256 total = depositPaid + msg.value;
        (bool success, ) = payable(owner).call{value: total}("");
        require(success, "Transferencia fallida");

        emit WinnerPaymentReceived(w, total);
    }

    // ═══════════════════════════════════════════════════════════════
    // FASE 5: FALLBACK — confiscar y pasar al siguiente
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Si el ganador actual no pagó en el plazo:
     *      - Confisca su depósito (va al owner)
     *      - Avanza al siguiente postor del ranking con plazo de pago fresco
     *      - Si no hay más postores o se alcanza maxFallbacks → subasta desierta
     */
    function confiscateAndAdvance() external onlyOwner isFinalized {
        require(!auctionDeserted,                          "Subasta ya desierta");
        require(!auctionSuccessful,                        "Subasta ya completada");
        require(currentWinnerIndex < rankedBidders.length, "Sin ganador activo");
        require(block.timestamp > paymentDeadline,         "Plazo aun activo");

        address defaulter = rankedBidders[currentWinnerIndex];

        // Confiscar depósito del incumplidor → owner
        uint256 penalty = bidders[defaulter].deposit;
        bidders[defaulter].hasWithdrawn = true;
        (bool success, ) = payable(owner).call{value: penalty}("");
        require(success, "Transferencia fallida");
        emit DepositConfiscated(defaulter, penalty);

        fallbackCount++;
        currentWinnerIndex++;

        bool noMoreBidders = currentWinnerIndex >= rankedBidders.length;
        bool maxReached    = fallbackCount >= maxFallbacks;

        if (noMoreBidders || maxReached) {
            auctionDeserted = true;
            emit AuctionDeserted();
        } else {
            // Asignar nuevo ganador con plazo fresco
            paymentDeadline   = block.timestamp + paymentDuration;
            address newWinner = rankedBidders[currentWinnerIndex];
            emit NewWinnerAssigned(
                newWinner,
                bidders[newWinner].revealedBid,
                fallbackCount
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // CIERRE: COBRAR FIANZAS DE NO-REVELADORES
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev El owner recoge de una vez las fianzas de quienes:
     *      - No llamaron a reveal() antes del revealDeadline
     *      - Llamaron a reveal() con datos incorrectos (hash no coincidió)
     *      Solo disponible tras la finalización.
     */
    function collectUnrevealedDeposits() external onlyOwner isFinalized {
        uint256 total = 0;

        for (uint256 i = 0; i < bidderList.length; i++) {
            address addr = bidderList[i];
            Bidder storage b = bidders[addr];

            if (!b.hasRevealed && !b.hasWithdrawn && b.deposit > 0) {
                b.hasWithdrawn = true;
                total += b.deposit;
                emit DepositConfiscated(addr, b.deposit);
            }
        }

        require(total > 0, "Nada que cobrar");
        (bool success, ) = payable(owner).call{value: total}("");
        require(success, "Transferencia fallida");
    }

    // ═══════════════════════════════════════════════════════════════
    // CIERRE: RETIRAR DEPÓSITO (perdedores que sí revelaron)
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Solo pueden retirar quienes:
     *      - Revelaron correctamente (hasRevealed = true)
     *      - No son el ganador actual
     *      Quien no reveló no puede retirar — su fianza va al owner via collectUnrevealedDeposits().
     */
    function withdrawDeposit() external isFinalized {
        // El ganador actual no puede retirar mientras tenga opción de pagar
        if (!auctionDeserted && !auctionSuccessful && currentWinnerIndex < rankedBidders.length) {
            require(
                msg.sender != rankedBidders[currentWinnerIndex],
                "Eres el ganador actual, paga o espera al deadline"
            );
        }

        Bidder storage b = bidders[msg.sender];
        require(b.deposit > 0,   "Sin deposito");
        require(!b.hasWithdrawn, "Ya retirado");
        require(b.hasRevealed,   "No revelaste: fianza confiscada");

        b.hasWithdrawn = true;
        uint256 amount = b.deposit;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transferencia fallida");

        emit DepositWithdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // KYC — VERIFICACIÓN CRIPTOGRÁFICA DE FIRMA
    // ═══════════════════════════════════════════════════════════════

    /**
     * @dev Verifica que la firma fue generada por el owner sobre la dirección del usuario.
     *      El owner genera la firma off-chain:
     *          signature = ownerWallet.signMessage(ethers.getBytes(ethers.keccak256(userAddress)))
     *
     * @param _user       Dirección del postor a verificar
     * @param _signature  Firma del owner (65 bytes: r + s + v)
     */
    function _verifyKYC(address _user, bytes memory _signature)
        internal view returns (bool)
    {
        // Reconstruye el hash del mensaje original
        bytes32 messageHash = keccak256(abi.encodePacked(_user));

        // Añade el prefijo estándar de Ethereum (EIP-191)
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );

        // Recupera la dirección que firmó y verifica que es el owner
        return _recoverSigner(ethSignedHash, _signature) == owner;
    }

    /**
     * @dev Recupera la dirección del firmante a partir del hash y la firma.
     *      Usa ecrecover — operación nativa de Ethereum.
     */
    function _recoverSigner(bytes32 _hash, bytes memory _signature)
        internal pure returns (address)
    {
        require(_signature.length == 65, "Firma con longitud invalida");

        bytes32 r;
        bytes32 s;
        uint8   v;

        assembly {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }

        return ecrecover(_hash, v, r, s);
    }

    /**
     * @dev Función pública para que el owner pueda verificar una firma antes de enviarla.
     *      También útil para pruebas en Remix.
     */
    function verifyKYC(address _user, bytes memory _signature)
        external view returns (bool)
    {
        return _verifyKYC(_user, _signature);
    }

    // ═══════════════════════════════════════════════════════════════
    // UTILIDADES DE CONSULTA
    // ═══════════════════════════════════════════════════════════════

    /// @dev Genera el hash de puja para usar en commit() — usar OFF-CHAIN en producción
    function hashBid(uint256 _amount, bytes32 _secret, address _bidder)
        public pure returns (bytes32)
    {
        return keccak256(abi.encodePacked(_amount, _secret, _bidder));
    }

    /// @dev Dirección del ganador actual (address(0) si no hay)
    function currentWinner() external view returns (address) {
        if (!finalized || auctionDeserted || rankedBidders.length == 0) return address(0);
        if (currentWinnerIndex >= rankedBidders.length) return address(0);
        return rankedBidders[currentWinnerIndex];
    }

    /// @dev Puja del ganador actual (0 si no hay)
    function currentWinningBid() external view returns (uint256) {
        if (!finalized || auctionDeserted || rankedBidders.length == 0) return 0;
        if (currentWinnerIndex >= rankedBidders.length) return 0;
        return bidders[rankedBidders[currentWinnerIndex]].revealedBid;
    }

    /// @dev Cuánto debe pagar todavía el ganador actual
    function remainingPayment() external view returns (uint256) {
        if (!finalized || auctionDeserted || auctionSuccessful) return 0;
        if (currentWinnerIndex >= rankedBidders.length) return 0;
        address w   = rankedBidders[currentWinnerIndex];
        uint256 bid = bidders[w].revealedBid;
        uint256 dep = bidders[w].deposit;
        return bid > dep ? bid - dep : 0;
    }

    /// @dev Número de postores en el ranking válido
    function getRankedCount() external view returns (uint256) {
        return rankedBidders.length;
    }

    /// @dev Número total de postores que han hecho commit
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
        paymentRemaining = (finalized && !auctionDeserted && !auctionSuccessful
                           && block.timestamp < paymentDeadline)
            ? paymentDeadline - block.timestamp : 0;
    }
}
