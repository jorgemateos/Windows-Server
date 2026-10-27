# Windows Server

Scripts de PowerShell para administrar y auditar Windows Server y Active Directory.

| Script | Descripción | Estado |
|---|---|---|
| [auditoria-ad](auditoria-ad/) | Auditoría de solo lectura de un controlador de dominio Windows Server 2025, con modo guiado e informes HTML, TXT y JSON. | En pruebas |

Cada carpeta contiene el script y su propio README con los requisitos, el uso y las limitaciones.

## Descargar un script en el servidor

Desde Windows PowerShell como administrador, por ejemplo para la auditoría de AD. La primera línea crea la carpeta de destino si no existe:

```powershell
New-Item -ItemType Directory -Path 'C:\Scripts' -Force | Out-Null
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/jorgemateos/Windows-Server/main/auditoria-ad/Auditoria-AD2025.ps1' -OutFile 'C:\Scripts\Auditoria-AD2025.ps1'
cd C:\Scripts
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Auditoria-AD2025.ps1
```

## Autor y licencia

Jorge Mateos — [jorgemateos.es](https://jorgemateos.es) · [LinkedIn](https://www.linkedin.com/in/jorgemateos-es/)

Licencia [GPL-3.0](LICENSE). Los scripts se distribuyen sin garantía: pruébalos antes en un entorno de laboratorio.
