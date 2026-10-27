# Auditoría guiada de Active Directory — Windows Server 2025

Script `Auditoria-AD2025.ps1` de **auditoría de solo lectura** para un controlador de dominio ya promocionado. Ofrece instrucciones en pantalla cuando detecta una configuración pendiente, espera al operador en `-Guiado` y vuelve a comprobar algunas condiciones. **El script no modifica Active Directory, no configura backups y no crea tareas programadas**. Las acciones que se realicen manualmente durante las pausas sí pueden modificar el entorno.

> Estado: probado con un controlador de dominio simulado (ver [Pruebas](#pruebas)). Primera ejecución en un Windows Server real realizada; sigue en pruebas. Pruébalo primero en laboratorio y revisa el informe.

## Requisitos

- Windows Server 2025 con Windows PowerShell 5.1, sesión elevada como administrador.
- Módulos `ActiveDirectory` y `DnsServer` disponibles, utilidades `dcdiag`, `repadmin`, `w32tm`.
- Para el inventario ampliado de backups: característica Windows Server Backup y módulo `WindowsServerBackup`.
- Permisos de lectura de AD DS, DNS, eventos y configuración del servidor. El script utiliza `#requires -RunAsAdministrator` y `#requires -Modules`.
- Archivo `.ps1` codificado como **UTF-8 con BOM** para compatibilidad con Windows PowerShell 5.1.

## Uso

Abre **Windows PowerShell como administrador** y entra en la carpeta del script. Si procede de una descarga de confianza y está bloqueado por Windows:

```powershell
Unblock-File -Path .\Auditoria-AD2025.ps1
```

Para ejecutar sin cambiar permanentemente la política de ejecución de PowerShell, tras comprobar las políticas de tu organización:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Auditoria-AD2025.ps1
```

Modo guiado, usando tus propios valores:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Auditoria-AD2025.ps1 -Guiado -Subred '192.168.100.0/24' -Sitio 'Madrid' -Reenviador '192.168.100.1'
```

Para ver la ayuda completa del script con todos los parámetros y ejemplos:

```powershell
Get-Help .\Auditoria-AD2025.ps1 -Full
```

`-ExecutionPolicy Bypass` se aplica únicamente a ese proceso; puede estar restringido por las políticas del dominio. No lo utilices para eludir controles de seguridad de tu organización.

## Parámetros

| Parámetro | Tipo | Valor predeterminado | Función |
|---|---|---|---|
| `-Guiado` | Switch | Desactivado | Muestra procedimientos y pausas para completar tareas manualmente. |
| `-Subred` | Cadena | Ninguno | Red IPv4 de referencia en CIDR, p. ej. `192.168.100.0/24`. Si no se indica, se omiten la comprobación de la subred y la de zona inversa/PTR. |
| `-Sitio` | Cadena | Ninguno | Site AD esperado para `-Subred`. Comprueba también la asociación de la subred existente. |
| `-Reenviador` | Cadena | Ninguno | Dirección IPv4 del reenviador DNS esperado. Sin ella solo se inventarían los reenviadores actuales. |
| `-Directorio` | Cadena | `C:\AD-Auditoria` | Directorio raíz de informes; se crea una carpeta por ejecución. |

**Los valores `192.168.100.0/24`, `Madrid` y `192.168.100.1` son ejemplos, no valores predeterminados.**

El script valida los parámetros antes de empezar y se detiene con un mensaje claro si no son correctos:

- `-Subred`: cada octeto entre 0 y 255, prefijo entre 0 y 32, y debe ser la **dirección de red** (por ejemplo, `192.168.100.5/24` se rechaza; lo correcto es `192.168.100.0/24`).
- `-Reenviador`: dirección IPv4 válida.

La zona inversa y el PTR se comprueban cuando `-Subred` es **/8, /16 o /24** y **contiene la IP del DC**. Con otros prefijos el script no supone cómo está diseñada la zona inversa y lo indica como información.

## Estados del informe

| Estado | Significado |
|---|---|
| **OK** | La comprobación es correcta. |
| **AVISO** | Hay algo que revisar o corregir. No siempre es una avería. |
| **ERROR** | La comprobación ha fallado o no se ha podido ejecutar. |
| **INFO** | Dato informativo. |
| **REVISAR** | El script no puede concluir nada por sí mismo: requiere revisión humana del log. |

## Comprobaciones

- **Identidad**: dominio, bosque, DC, FSMO (indicando si este DC es el PDC Emulator) y catálogo global.
- **Red y Sites**: IPv4, DNS cliente, pertenencia de la IP del DC a la subred, existencia de la subred y su asociación al Site.
- **DNS**, cada prueba por separado para que un fallo no interrumpa las demás:
  - zona principal y zona `_msdcs`;
  - zona inversa;
  - registro PTR en la zona **y** consulta DNS real del PTR contra el propio DC;
  - reenviadores;
  - resolución SOA, SRV y externa.
  
  Las consultas distinguen entre *el nombre no existe* (AVISO) y *fallo de consulta*, como un timeout o un servidor que no responde (ERROR).
- **SYSVOL**: recursos SYSVOL y NETLOGON, estado DFSR y eventos DFSR de las últimas 24 h.
- **Recuperación**: Papelera de reciclaje de AD (ignorando valores nulos) y retenciones; si `msDS-deletedObjectLifetime` no está definido, se indica que hereda `tombstoneLifetime`.
- **Sistema**: versión, último KB observado y SMB.
- **Hora (W32Time)**:
  - rol del DC: el PDC Emulator debe usar una fuente externa (`Type=NTP`) y el resto, la jerarquía del dominio (`Type=NT5DS`);
  - origen de la hora y detección de reloj local o del hipervisor;
  - estado de sincronización: indicador de salto, stratum y última sincronización correcta (aviso si han pasado más de 24 h);
  - diferencia horaria medida con `w32tm /stripchart`: el PDC se compara con su fuente externa y el resto de DC con el PDC. Avisa a partir de 1 s y da error a partir de 5 min, el límite de Kerberos. Es una consulta NTP de solo lectura y no cambia la hora.
- **Servicios**: NTDS, DNS, Netlogon, DFSR, KDC y W32Time.
- **DCDIAG y repadmin**: guardan los logs completos. Una prueba solo se marca como superada si el texto lo dice expresamente. Si el idioma o el formato no se reconoce, queda como **REVISAR**: el script nunca da por buena una prueba solo porque no encuentre palabras de error.
- **Backups**: inventario y tabla de estados (ver siguiente sección).

## Backups

### Estado de las copias

Cada consulta (catálogo `wbadmin`, `Get-WBPolicy`, `Get-WBSummary` y tareas programadas) se ejecuta por separado, así que si una falla las demás continúan. Con esos datos el informe muestra una tabla que separa lo que el script puede comprobar de lo que no:

| Estado | Cómo se determina |
|---|---|
| Configurado | Existe una política de Windows Server Backup, o tareas programadas candidatas (REVISAR). |
| Programado | La política tiene horarios (`Get-WBSchedule`), o hay tareas candidatas habilitadas (REVISAR). |
| Ejecutado | `Get-WBSummary` registra un intento de copia. |
| Correcto | La última copia terminó bien y tiene menos de 7 días. |
| Recuperable | **No verificable por el script**: que haya versiones en el catálogo no garantiza que se puedan restaurar. |
| Restauración probada | **Requiere una prueba manual documentada** en un entorno aislado. |

Si se usa otro software de copias (Veeam, NAKIVO...), el script lo indica como REVISAR y hay que comprobarlo en esa herramienta.

`wbadmin get status` solo se consulta para saber si **hay una copia en curso**, nunca para deducir la programación.

### Asistente de planificación

En modo `-Guiado` hay tres planes **separados**: System State, Bare Metal Recovery y Full Server. El operador puede documentar destino, frecuencia, horario y retención prevista para cada tipo. **Solo registra la planificación; no programa ni ejecuta las copias**. Windows Server Backup puede imponer restricciones de destino y retención; las tres modalidades comparten datos y no equivalen a tres copias independientes.

## Informes y evidencias

En `C:\AD-Auditoria\Auditoria-AAAAmmdd-HHMMSS\`, o bajo `-Directorio`:

| Archivo | Contenido |
|---|---|
| `informe.html` | Informe visual con comprobaciones y tabla de estado de las copias. |
| `informe.txt` | Resumen, estado de copias, guías y planes de backup. |
| `informe.json` | Datos estructurados (incluye `EstadoBackups` y `PlanBackups`). |
| `dcdiag-*.txt`, `repadmin-*.txt` | Diagnósticos completos, sin modificar configuración. |
| `w32tm-source.txt`, `w32tm-status.txt`, `w32tm-configuration.txt`, `w32tm-peers.txt`, `w32tm-stripchart.txt` | Origen, estado, configuración, pares y diferencia horaria. |
| `volumenes.json` | Inventario de discos y volúmenes. |
| `wbadmin-versiones.txt`, `wbadmin-estado.txt` | Catálogo y copia en curso **solo si Windows Server Backup está instalado**. |
| `wb-policy.txt`, `wb-summary.txt` | Política y resumen WSB **si el módulo devuelve datos**. |
| `tareas-backup-candidatas.json` | Tareas cuyo nombre sugiere copias; una coincidencia en el nombre no confirma el trabajo. |

**Seguridad de datos:** los informes pueden contener direcciones IP internas, nombres de equipos y configuraciones sensibles. No los publiques íntegros en GitHub. La carpeta incluye un `.gitignore` que los excluye.

## Limitaciones

- Solo lectura de Active Directory y su configuración: el script **sí escribe archivos locales de informes** y hace consultas DNS y NTP de lectura.
- El modo guiado muestra pasos manuales; no garantiza que se hayan efectuado correctamente.
- DCDIAG, `repadmin` y `w32tm` cambian de texto según idioma y versión: lo que no se reconoce queda como REVISAR.
- Las alertas de eventos históricos no necesariamente indican problemas actuales.
- No calcula el parche más reciente disponible ni certifica el estado de Windows Update.
- No configura un segundo controlador, privilegios Tier, LDAP/NTLM ni restauraciones.

## Pruebas

El script se ha ejecutado de principio a fin en PowerShell simulando un controlador de dominio en estos escenarios:

- **PDC correcto**, con salidas en inglés.
- **PDC con problemas** en modo `-Guiado`, con salidas en español: sin subred, sin zona inversa, sin reenviadores, Papelera con valor nulo, reloj local sin sincronizar y última copia fallida.
- **DC que no es PDC**, con un PTR incorrecto, un timeout de DNS, un desfase de 2,5 s y DCDIAG en un idioma no reconocido.
- **Sin parámetros** y con una **subred /16**.
- **Validación de parámetros**, con valores válidos e inválidos.

En todos los casos el script termina, genera todos los informes y solo muestra ERROR cuando el fallo es real (el timeout simulado). La versión 4 se ha ejecutado en un servidor real, donde apareció el fallo corregido en la 4.1. En tu laboratorio, revisa especialmente las salidas de `w32tm` en español, `Get-WBPolicy`, `Get-WBSummary` y los resultados del informe.

## Historial de cambios

**Versión 4.1**
- El módulo `WindowsServerBackup` se carga una sola vez. Al cargarlo dos veces, el propio módulo de Microsoft mostraba errores `New-Alias ... Get-WBVssBackupOptions already exists`, aunque la auditoría continuaba.

**Versión 4**
- Papelera de reciclaje: se filtran los valores nulos de `EnabledScopes`, que podían dar un falso "habilitada".
- Validación real de `-Subred` (octetos, prefijo y dirección de red) y de `-Reenviador`; comprobación de que la IP del DC pertenece a la subred.
- Zona inversa y PTR también para redes /8 y /16.
- DNS: cada prueba en un bloque independiente; el PTR se comprueba en la zona y con una consulta real, y se distingue "no existe" de "fallo de consulta".
- Backups: consultas independientes y tabla de estados (configurado, programado, ejecutado, correcto, recuperable, restauración probada).
- Hora: rol PDC frente al resto de DC, tipo de sincronización, stratum, indicador de salto, última sincronización y diferencia horaria.
- DCDIAG: nuevo estado REVISAR cuando el resultado no es concluyente; nunca se da por buena una prueba por ausencia de errores.
- Corregido un fallo que detenía la comprobación de la zona inversa cuando esta no existía.
- Las guías largas del informe HTML se ajustan al ancho de la página.

**Versión 3**
- Archivo guardado como UTF-8 con BOM.
- Ayuda completa con `Get-Help`.
- Corregida la pregunta del asistente de backups, que detenía el script.
- Funciona aunque el servidor no tenga ninguna actualización (KB) instalada.
- Un solo aviso cuando solo hay un DC, en lugar de dos.
- Recomendaciones de reenvío DNS válidas para cualquier firewall, no solo pfSense.

**Versión 2**
- Los comandos `dcdiag`, `repadmin`, `w32tm` y `wbadmin` ya no detienen la auditoría si devuelven errores.
- Lectura segura de atributos de AD vacíos y de servidores DNS sin reenviadores.
- Parámetros de red opcionales, comprobación de la asociación Site/subred y guía de PTR solo si existe la zona inversa.

## Autor y licencia

Jorge Mateos — [jorgemateos.es](https://jorgemateos.es) · [LinkedIn](https://www.linkedin.com/in/jorgemateos-es/)

Licencia [GPL-3.0](../LICENSE), la misma del repositorio. Se distribuye sin garantía: pruébalo antes en un entorno de laboratorio.
