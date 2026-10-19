# OpenDrop en Windows (WSL2 + adaptador Wi-Fi USB)

Este fork deja OpenDrop funcionando en Windows 11 contra iPhones actuales
(iOS 26), en los dos sentidos, sin Apple ID. Se apoya en:

- **OpenDrop** de seemoo-lab, con la serie de 17 parches de
  [airdrop-mt7921](https://github.com/jedbillyb/airdrop-mt7921) para iOS 26
  (cuerpos chunked, contenedor `dvzip`, `TransferID` en `/Ask`, servidor
  multihilo, re-anuncio mDNS, etc.), más los PR #132 (arranque sin
  `pkg_resources`) y #134 (path traversal) de upstream, este último adaptado
  al código parcheado.
- **OWL** (AWDL) del [fork de jedbillyb](https://github.com/bluque-garcia/owl),
  que sigue la secuencia de canales de iOS 26.
- **WSL2** con drivers Wi-Fi USB compilados para su kernel, y **usbipd-win**
  para pasarle el adaptador.

## Por qué hace falta un adaptador USB

AirDrop va sobre AWDL, y OWL necesita una tarjeta con *monitor mode activo e
inyección de tramas*. El Wi-Fi interno (Intel BE200) no lo ofrece, y aunque
lo ofreciera es PCIe y WSL no puede usarlo. Un adaptador USB sí se puede pasar
a WSL, y queda dedicado a AirDrop: **Windows sigue con internet por el Wi-Fi
interno** todo el tiempo.

Adaptadores soportados (drivers que compila `wsl/build-wifi-modules.sh`):

| Chip | Ejemplos | Notas |
|---|---|---|
| **MT7921AU** | Alfa AWUS036AXML, Netgear A8000 | **Recomendado**: es el chip con el que se probó iOS 26 de punta a punta (en su versión PCIe). Doble banda. |
| MT7612U | Alfa AWUS036ACM, Netgear A6210 | Doble banda, monitor e inyección muy maduros. |
| AR9271 | TP-Link TL-WN722N **v1**, Alfa AWUS036NHA | Solo 2,4 GHz (canal AWDL 6). Ojo: la v2/v3 del TL-WN722N es otro chip. |
| MT7610U, RT5370/RT5572 | varios | Funcionan con OWL; menos probados. |

## Instalación (una vez)

1. Instalar usbipd-win: `winget install dorssel.usbipd-win`
2. Preparar WSL (paquetes, OWL, OpenDrop y drivers; la primera vez compila
   el kernel, unos 15-20 min):

   ```
   windows\AirDrop.cmd setup
   ```

   **Repetir tras cada `wsl --update`**: los drivers son para una versión de
   kernel concreta.
3. Conectar el adaptador. La primera vez que se use, Windows pedirá permisos
   de administrador una sola vez para compartirlo con WSL (`usbipd bind`).

## Uso

En el iPhone: **Ajustes > General > AirDrop > Todos durante 10 minutos**
(«Solo contactos» exige una identidad firmada por Apple que no se puede
generar fuera de su hardware). iOS lo vuelve a quitar a los 10 minutos.

**Recibir** (doble clic en `windows\AirDrop.cmd`, o):

```
windows\AirDrop.cmd
```

En el iPhone, abre el menú Compartir > AirDrop y elige este PC. Saldrá un
diálogo en Windows para aceptar o rechazar (30 s sin respuesta = rechazo).
Los archivos llegan a `Descargas\AirDrop`. Los enlaces se abren en el
navegador predeterminado. `Ctrl+C` para parar.

**Enviar** (el iPhone desbloqueado y con el menú Compartir **cerrado**):

```
windows\AirDrop.cmd send foto.jpg informe.pdf
windows\AirDrop.cmd send foto.jpg -Receiver "iPhone de Ana"
```

El lanzador emite el anuncio Bluetooth LE de AirDrop desde Windows para
despertar el AWDL del iPhone (WSL no tiene Bluetooth).

**Diagnóstico**:

```
windows\AirDrop.cmd doctor     # adaptador, driver y canales con tráfico AWDL
windows\AirDrop.cmd find       # receptores AirDrop al alcance
windows\AirDrop.cmd detach     # devolver el adaptador a Windows
```

Opciones del lanzador: `-Name` (nombre que ve el iPhone), `-ReceiveDir`,
`-Channel 6|44|149` (si no, barre y elige el de más tráfico), `-BusId` (para
un adaptador que no está en la lista), `-Distro`.

Logs de cada ejecución en WSL: `/var/log/airdrop/<fecha>-<modo>/` (owl.log,
receive.log, capturas pcap).

## Detalles de WSL que resuelve el lanzador

- **Firmware**: el kernel de WSL carga firmware desde el namespace raíz de la
  VM, no desde Ubuntu, así que `/lib/firmware` de la distro no le sirve
  (`Direct firmware load ... failed with error -2`). `airdrop-wsl.sh prepare`
  copia los blobs a `/mnt/wsl/airdrop-firmware` (tmpfs compartido con ese
  namespace) y apunta `firmware_class.path` ahí. Tiene que ocurrir **antes**
  de conectar el adaptador, y se pierde al reiniciar WSL; el lanzador lo hace
  en cada ejecución.
- **Dominio regulatorio**: por el mismo motivo `regulatory.db` no se cargaba
  y quedaba el dominio mundial, que prohíbe emitir en todo 5 GHz (canales
  AWDL 44 y 149). Con el firmware preparado se aplica `ES` (o `-Country`).
- **Firmware comprimido**: Ubuntu lo trae en `.zst` y el kernel de WSL solo
  descomprime XZ; `build-wifi-modules.sh` deja copias sin comprimir.

## Limitaciones conocidas

- **Velocidad**: unos 40-70 kB/s; una foto de 3-4 MB tarda 1-2 minutos.
  Es una limitación de OWL (ocupa pocos *slots* AWDL), no del USB.
- **Latencia de USB/IP**: AWDL trabaja con ventanas de ~16 ms. usbipd añade
  algo de latencia; no está medido si afecta. Si la sincronización falla
  sistemáticamente, la alternativa es arrancar Linux nativo (USB live) con el
  mismo adaptador.
- Solo modo «Todos». Sin autenticación del emisor: por eso el diálogo de
  confirmación está activado por defecto.

## Estructura añadida

```
windows/AirDrop.ps1, AirDrop.cmd   lanzador: usbipd + WSL + BLE
windows/ble-wake.ps1               anuncio BLE de AirDrop vía WinRT
wsl/setup-wsl.sh                   instala todo en /opt/airdrop
wsl/build-wifi-modules.sh          drivers Wi-Fi USB para el kernel de WSL
wsl/airdrop-wsl.sh                 orquestador: radio -> owl -> opendrop
wsl/confirm-windows.sh             diálogo de aceptación en Windows
wsl/open-url-windows.sh            abre enlaces recibidos en Windows
wsl/airdrop-tidy                   aplana NSIRD_AirDrop_* (de airdrop-mt7921)
```
