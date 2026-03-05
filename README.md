# Blind Auction (Commit-Reveal) - Hackathon Prototype

Prototipo base de subasta a sobre cerrado en Solidity para Sepolia.

El objetivo es educativo: mostrar un flujo simple y entendible de **commit-reveal** para evitar que las pujas se vean durante la fase de compromiso.

## Contrato

- Archivo principal: `BlindAuction.sol`
- Versión de Solidity: `^0.8.20`
- Red objetivo: Sepolia (testnet)

## Idea del esquema commit-reveal

Cada postor no publica su puja real al principio.

1. **Commit phase**: envía un hash con:
   - `keccak256(abi.encode(bidAmount, secret))`
   - junto con un depósito en `msg.value`
2. **Reveal phase**: revela `bidAmount` y `secret`
3. El contrato recalcula el hash y verifica si coincide con el commit.

Si coincide, la puja es válida. Si no coincide, se ignora.

## Funciones principales

- `commitBid(bytes32 commitHash) payable`
  - Guarda el hash comprometido y el depósito del usuario.
- `revealBid(uint256 bidAmount, string memory secret)`
  - Verifica el hash revelado y actualiza ganador si corresponde.
- `finalizeAuction()`
  - Cierra la subasta al terminar reveal y transfiere la puja ganadora al owner.
- `withdraw()`
  - Permite retirar fondos:
    - No ganadores: retiran todo su depósito.
    - Ganador: retira solo el excedente (`deposit - highestBid`).

## Tiempos de la subasta

Se definen en el constructor:

- `commitDeadline`
- `revealDeadline`

Parámetros:

- `commitDuration` (segundos)
- `revealDuration` (segundos)

## Demo rápida en Remix + MetaMask + Sepolia

1. Abrir [Remix](https://remix.ethereum.org/).
2. Crear/importar `BlindAuction.sol`.
3. Compilar con versión 0.8.20+.
4. En Deploy, elegir **Injected Provider - MetaMask** (red Sepolia).
5. Desplegar con:
   - `commitDuration = 180` (3 min, por ejemplo)
   - `revealDuration = 180`
6. Desde cuentas participantes:
   - calcular hash fuera del contrato (con mismo `bidAmount` y `secret`)
   - llamar `commitBid(hash)` enviando ETH como depósito.
7. Esperar fin de commit.
8. Cada participante llama `revealBid(bidAmount, secret)`.
9. Tras `revealDeadline`, llamar `finalizeAuction()`.
10. Cada usuario llama `withdraw()` para recuperar lo que corresponda.

## Cómo calcular el hash (importante)

El hash debe usar exactamente:

- `keccak256(abi.encode(bidAmount, secret))`

Si el hash se calcula con otro formato (por ejemplo `encodePacked`), el reveal fallará.

## Limitaciones intencionales de este prototipo

- No incluye frontend.
- No incluye NFTs ni features avanzadas.
- No usa optimizaciones ni patrones complejos.
- Está pensado para explicar el concepto base en una presentación.
