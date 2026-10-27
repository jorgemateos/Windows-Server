#requires -Version 5.1
#requires -RunAsAdministrator
#requires -Modules ActiveDirectory, DnsServer

<#
.SYNOPSIS
 Audita un controlador de dominio Windows Server 2025 y genera documentacion local.
.DESCRIPTION
 Solo lectura siempre. -Guiado muestra instrucciones para completar tareas manualmente
 y espera INTRO antes de continuar. No realiza cambios sobre Active Directory.
 Estados del informe: OK, AVISO, ERROR, INFO y REVISAR (requiere revision humana).
.PARAMETER Guiado
 Muestra procedimientos manuales y espera INTRO antes de volver a comprobar.
.PARAMETER Subred
 Subred IPv4 de referencia en formato CIDR, por ejemplo 192.168.100.0/24. Opcional.
 Debe ser una direccion de red valida (octetos 0-255, prefijo 0-32, bits de host a cero).
.PARAMETER Sitio
 Site de Active Directory al que deberia estar asociada la subred. Opcional.
.PARAMETER Reenviador
 Direccion IPv4 del reenviador DNS esperado. Opcional.
.PARAMETER Directorio
 Carpeta raiz de los informes. Por defecto C:\AD-Auditoria.
.EXAMPLE
 .\Auditoria-AD2025.ps1
.EXAMPLE
 .\Auditoria-AD2025.ps1 -Guiado -Subred '192.168.100.0/24' -Sitio 'Madrid' -Reenviador '192.168.100.1'
.NOTES
 Autor: Jorge Mateos - https://jorgemateos.es
 Version 4
#>
[CmdletBinding()]
param(
 [switch]$Guiado,
 [string]$Subred,
 [string]$Sitio,
 [string]$Reenviador,
 [string]$Directorio = 'C:\AD-Auditoria'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

############################ Funciones auxiliares de red ############################
function ConvertTo-IPv4Number([string]$Text) {
 # Devuelve la IPv4 como entero de 32 bits (en Int64) o $null si no es valida.
 if([string]::IsNullOrWhiteSpace($Text)){ return $null }
 if($Text.Trim() -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'){ return $null }
 [int64]$n=0
 foreach($i in 1..4){
  $o=[int64]$Matches[$i]
  if($o -gt 255){ return $null }
  $n=($n * 256) + $o
 }
 return $n
}
function ConvertTo-IPv4Network([string]$Cidr) {
 # Valida una red IPv4 en CIDR. Devuelve un objeto o $null si no es valida.
 if([string]::IsNullOrWhiteSpace($Cidr)){ return $null }
 $parts=$Cidr.Trim().Split('/')
 if($parts.Count -ne 2 -or $parts[1] -notmatch '^\d{1,2}$'){ return $null }
 $prefix=[int]$parts[1]
 if($prefix -lt 0 -or $prefix -gt 32){ return $null }
 $addr=ConvertTo-IPv4Number $parts[0]
 if($null -eq $addr){ return $null }
 [int64]$mask=if($prefix -eq 0){0}else{ ([int64]4294967296) - [int64][math]::Pow(2,32-$prefix) }
 if(($addr -band $mask) -ne $addr){ return $null }   # bits de host distintos de cero
 return [pscustomobject]@{Text=$parts[0].Trim();Prefix=$prefix;Address=$addr;Mask=$mask}
}
function Test-IPv4InNetwork([string]$Ip,[object]$Network) {
 $n=ConvertTo-IPv4Number $Ip
 if($null -eq $n -or $null -eq $Network){ return $false }
 return (($n -band $Network.Mask) -eq $Network.Address)
}

############################ Validacion de parametros ############################
$script:net=$null
if(-not [string]::IsNullOrWhiteSpace($Subred)){
 $script:net=ConvertTo-IPv4Network $Subred
 if($null -eq $script:net){
  throw "Parametro -Subred no valido: '$Subred'. Usa una red IPv4 en CIDR con octetos 0-255, prefijo 0-32 y bits de host a cero (p. ej. 192.168.100.0/24)."
 }
 $Subred="$($script:net.Text)/$($script:net.Prefix)"
}
if(-not [string]::IsNullOrWhiteSpace($Reenviador) -and $null -eq (ConvertTo-IPv4Number $Reenviador)){
 throw "Parametro -Reenviador no valido: '$Reenviador'. Debe ser una direccion IPv4 (p. ej. 192.168.100.1)."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $Directorio "Auditoria-$stamp"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$script:checks = New-Object System.Collections.Generic.List[object]
$script:guides = New-Object System.Collections.Generic.List[object]
$script:backups = New-Object System.Collections.Generic.List[object]
$script:wbState = New-Object System.Collections.Generic.List[object]
$script:domain = $null
$script:forest = $null
$script:dc = $null
$script:fqdn = $null
$script:isPdc = $false

############################ Funciones generales ############################
function Add-Check([string]$Area,[string]$Prueba,[string]$Estado,[string]$Detalle,[string]$Recomendacion='') {
 $script:checks.Add([pscustomobject]@{Area=$Area;Prueba=$Prueba;Estado=$Estado;Detalle=$Detalle;Recomendacion=$Recomendacion})
 $color = switch($Estado){'OK'{'Green'} 'AVISO'{'Yellow'} 'ERROR'{'Red'} 'REVISAR'{'Magenta'} default {'Cyan'}}
 Write-Host ("[{0}] {1}: {2}" -f $Estado,$Area,$Prueba) -ForegroundColor $color
}
function Safe([scriptblock]$Block,[string]$Area,[string]$Prueba) {
 try { & $Block } catch { Add-Check $Area $Prueba 'ERROR' $_.Exception.Message 'Revisar este fallo antes de la puesta en produccion.' }
}
function Show-Guide([string]$Area,[string]$Title,[string]$Instructions) {
 if(-not $Guiado){return}
 Write-Host "`n=================================================" -ForegroundColor Cyan
 Write-Host "GUIA MANUAL: $Title" -ForegroundColor Yellow
 Write-Host $Instructions -ForegroundColor White
 Write-Host "No se modificara nada automaticamente." -ForegroundColor DarkYellow
 $answer=Read-Host 'Realiza la tarea si procede y pulsa INTRO para continuar (escribe OMITIR para dejarla pendiente)'
 $state=if($answer -eq 'OMITIR'){'Omitida'}else{'Continuar; verificar resultado'}
 $script:guides.Add([pscustomobject]@{Area=$Area;Tarea=$Title;Instrucciones=$Instructions;Respuesta=$state})
}
function Invoke-NativeEvidence([string]$Executable,[string[]]$Arguments,[string]$FileName) {
 # En Windows PowerShell 5.1, stderr redirigido con 2>&1 puede generar
 # registros ErrorRecord. No debe cancelar el resto de la auditoria.
 $file = Join-Path $runDir $FileName
 $previous = $ErrorActionPreference
 try {
  $ErrorActionPreference = 'Continue'
  $output = & $Executable @Arguments 2>&1 | Out-String
  $code = $LASTEXITCODE
  $output | Set-Content -Path $file -Encoding UTF8
  return [pscustomobject]@{ExitCode=$code;Output=[string]$output;File=$file}
 } catch {
  $_.Exception.Message | Set-Content -Path $file -Encoding UTF8
  return [pscustomobject]@{ExitCode=-1;Output=$_.Exception.Message;File=$file}
 } finally { $ErrorActionPreference = $previous }
}
function Get-OptionalProperty([object]$Object,[string]$Name) {
 # Lee una propiedad que puede no existir sin romper Set-StrictMode.
 if($null -eq $Object){ return $null }
 $prop = $Object.PSObject.Properties[$Name]
 if($null -eq $prop -or $null -eq $prop.Value) { return $null }
 return $prop.Value
}
function Get-NonNullItems([object]$Value) {
 # @($null) contiene un elemento nulo: filtrarlo antes de contar.
 return ,@(@($Value) | Where-Object { $null -ne $_ })
}
function Get-ForwarderIPs {
 $items = @(Get-DnsServerForwarder -ComputerName 'localhost' -ErrorAction Stop)
 $ips = @()
 foreach($item in $items) {
  foreach($addr in (Get-NonNullItems (Get-OptionalProperty $item 'IPAddress'))) { $ips += $addr.ToString() }
 }
 return $ips
}
function Get-RecycleBinScopes {
 $feature=Get-ADOptionalFeature -Identity 'Recycle Bin Feature'
 return ,(Get-NonNullItems (Get-OptionalProperty $feature 'EnabledScopes'))
}
function Get-DnsFailureKind([object]$ErrorRecord) {
 # Distingue "no existe" de un fallo real de consulta (timeout, servidor caido...).
 $id=[string]$ErrorRecord.FullyQualifiedErrorId
 $code=Get-OptionalProperty $ErrorRecord.Exception 'NativeErrorCode'
 if($id -match 'DNS_ERROR_RCODE_NAME_ERROR' -or $code -eq 9003){ return 'NoExiste' }
 if($id -match 'DNS_INFO_NO_RECORDS' -or $code -eq 9501){ return 'SinRegistros' }
 return 'Fallo'
}
function Test-DnsQuery([string]$Name,[string]$Type,[string]$Server) {
 try {
  $answer=@(Resolve-DnsName -Name $Name -Type $Type -Server $Server -DnsOnly -ErrorAction Stop)
  $typed=@($answer | Where-Object { [string](Get-OptionalProperty $_ 'Type') -eq $Type })
  if($typed.Count){ Add-Check 'DNS' "Consulta $Type $Name" 'OK' "Registros $Type=$($typed.Count); servidor=$Server" }
  else { Add-Check 'DNS' "Consulta $Type $Name" 'AVISO' "Respuesta sin registros $Type; servidor=$Server" }
 } catch {
  $err=$_   # dentro de switch, $_ pasa a ser el valor evaluado
  switch(Get-DnsFailureKind $err){
   'NoExiste'     { Add-Check 'DNS' "Consulta $Type $Name" 'AVISO' "El nombre no existe (NXDOMAIN); servidor=$Server" }
   'SinRegistros' { Add-Check 'DNS' "Consulta $Type $Name" 'AVISO' "El nombre existe pero no tiene registros $Type; servidor=$Server" }
   default        { Add-Check 'DNS' "Consulta $Type $Name" 'ERROR' "Fallo de consulta: $($err.Exception.Message)" 'Comprobar que el servicio DNS responde en esta IP y que no hay bloqueo de firewall.' }
  }
 }
}
function Get-DnsZoneInfo([string]$ZoneName) {
 # La coma evita que una lista vacia se convierta en $null al devolverla.
 return ,@(Get-DnsServerZone -ComputerName 'localhost' | Where-Object { $_.ZoneName -eq $ZoneName })
}
function Get-TextValue([string]$Text,[string]$LabelPattern) {
 # Extrae el valor de una linea "Etiqueta: valor" (salidas de w32tm, en ingles o espanol).
 $m=[regex]::Match([string]$Text,"(?im)^\s*(?:$LabelPattern)\s*:\s*(.+?)\s*$")
 if($m.Success){ return $m.Groups[1].Value }
 return $null
}
function Test-ValidDate([object]$Value) { return ($Value -is [datetime] -and $Value.Year -gt 2000) }
function Add-BackupState([string]$Estado,[string]$Valor,[string]$Status,[string]$Detalle) {
 $script:wbState.Add([pscustomobject]@{Estado=$Estado;Valor=$Valor;Detalle=$Detalle})
 Add-Check 'Backups' "Estado: $Estado" $Status "$Valor. $Detalle"
}
function Encode([object]$x){ return [System.Net.WebUtility]::HtmlEncode([string]$x) }

Write-Host "Auditoria de Active Directory - $env:COMPUTERNAME - $stamp" -ForegroundColor Cyan
Write-Host 'Modo: solo lectura; -Guiado ofrece instrucciones y pausas para tareas manuales.'

############################ Identidad ############################
Safe {
 Import-Module ActiveDirectory
 Import-Module DnsServer
 $script:domain=Get-ADDomain
 $script:forest=Get-ADForest
 $script:dc=Get-ADDomainController -Identity $env:COMPUTERNAME
 $script:fqdn=$script:dc.HostName
 $script:isPdc=([string]$domain.PDCEmulator -ieq [string]$dc.HostName)
 Add-Check 'Identidad' 'Dominio/bosque/controlador' 'OK' ("Dominio={0}; NetBIOS={1}; Bosque={2}; DC={3}; SO={4}; IP={5}; Site={6}" -f $domain.DNSRoot,$domain.NetBIOSName,$forest.Name,$dc.HostName,$dc.OperatingSystem,$dc.IPv4Address,$dc.Site)
 Add-Check 'Identidad' 'Niveles funcionales' 'INFO' ("DomainMode={0}; ForestMode={1}" -f $domain.DomainMode,$forest.ForestMode)
 Add-Check 'Identidad' 'FSMO' 'INFO' ("PDC={0}; RID={1}; Infra={2}; Schema={3}; Naming={4}; este DC es PDC={5}" -f $domain.PDCEmulator,$domain.RIDMaster,$domain.InfrastructureMaster,$forest.SchemaMaster,$forest.DomainNamingMaster,$script:isPdc)
 Add-Check 'Identidad' 'Catalogo global' $(if($dc.IsGlobalCatalog){'OK'}else{'AVISO'}) "IsGlobalCatalog=$($dc.IsGlobalCatalog)"
} 'Identidad' 'Carga de modulos y datos AD'

############################ Red ############################
Safe {
 $ip = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -eq $dc.IPv4Address })
 $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { @($_.ServerAddresses).Count -gt 0 } | ForEach-Object { "$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')" })
 Add-Check 'Red' 'Direccion del controlador y DNS cliente' $(if($ip.Count -gt 0){'OK'}else{'AVISO'}) ("IP AD={0}; Interfaces DNS={1}" -f $dc.IPv4Address,($dns -join ' | ')) 'Los DNS del adaptador del DC deben apuntar solo a DNS internos que resuelvan AD.'
} 'Red' 'Adaptadores'

############################ Sites y subred ############################
$script:dcInNet=$false
Safe {
 if($null -eq $script:net) {
  Add-Check 'Sites' 'Subred de referencia' 'INFO' 'No indicada: se omite la comparacion con una subred especifica.'
  return
 }
 $script:dcInNet=Test-IPv4InNetwork ([string]$dc.IPv4Address) $script:net
 Add-Check 'Sites' "IP del DC dentro de $Subred" $(if($script:dcInNet){'OK'}else{'INFO'}) $(if($script:dcInNet){"$($dc.IPv4Address) pertenece a la subred."}else{"$($dc.IPv4Address) no pertenece a la subred: se omiten zona inversa y PTR derivados de -Subred."})
 $sub = @(Get-ADReplicationSubnet -Filter * -Properties Site | Where-Object {$_.Name -eq $Subred})
 $checkSite = -not [string]::IsNullOrWhiteSpace($Sitio)
 $sitePattern = if($checkSite){'^CN=' + [regex]::Escape($Sitio) + ',|^' + [regex]::Escape($Sitio) + '$'}else{'.'}
 $siteIsCorrect = $sub.Count -gt 0 -and (-not $checkSite -or [string]$sub[0].Site -match $sitePattern)
 if($siteIsCorrect) {
  Add-Check 'Sites' "Subred $Subred" 'OK' ("Asociacion={0}" -f $sub[0].Site)
 } else {
  $detail=if($sub.Count){"Existe, pero esta asociada a $($sub[0].Site); Site esperado=$Sitio"}else{'No se ha encontrado'}
  Add-Check 'Sites' "Subred $Subred" 'AVISO' $detail 'Crear o asociar la subnet al Site apropiado.'
  Show-Guide 'Sites' "Comprobar subred $Subred" @"
1. Abre Sitios y servicios de Active Directory (dssite.msc).
2. Expande Sites > Subnets.
3. Si no existe, usa New Subnet y escribe: $Subred.
4. Asocia al Site correspondiente$(if($checkSite){": $Sitio"}else{' (verifica topologia y ubicacion)'}).
5. Si existe, abre Propiedades y confirma su asociacion.
"@
  if($Guiado){
   $post=@(Get-ADReplicationSubnet -Filter * -Properties Site | Where-Object Name -eq $Subred)
   $postOK=$post.Count -gt 0 -and (-not $checkSite -or [string]$post[0].Site -match $sitePattern)
   Add-Check 'Sites' "Reverificacion subred $Subred" $(if($postOK){'OK'}else{'AVISO'}) $(if($post.Count){"Asociacion=$($post[0].Site)"}else{'Sigue sin existir'})
  }
 }
} 'Sites' 'Subred AD'

############################ DNS (cada prueba en su propio bloque) ############################
foreach($zoneName in @([string](Get-OptionalProperty $domain 'DNSRoot'),"_msdcs.$([string](Get-OptionalProperty $forest 'RootDomain'))")){
 Safe {
  $z=Get-DnsZoneInfo $zoneName
  if($z.Count){
   $x=$z[0]; $status=if($x.IsDsIntegrated -and ([string]$x.DynamicUpdate -eq 'Secure')){'OK'}else{'AVISO'}
   Add-Check 'DNS' "Zona $zoneName" $status ("Integrada={0}; Scope={1}; Actualizaciones={2}; Tipo={3}" -f $x.IsDsIntegrated,$x.ReplicationScope,$x.DynamicUpdate,$x.ZoneType)
  }else{Add-Check 'DNS' "Zona $zoneName" 'AVISO' 'No visible como zona independiente; revisar delegacion o presencia dentro de la zona del dominio.'}
 } 'DNS' "Zona $zoneName"
}

# Zona inversa: solo con prefijos /8, /16 o /24 que contengan la IP del DC.
$script:rev=$null
$script:ptrName=$null
$script:revExists=$false
Safe {
 if($null -eq $script:net -or -not $script:dcInNet -or @(8,16,24) -notcontains $script:net.Prefix){
  Add-Check 'DNS' 'Zona inversa y PTR' 'INFO' 'Se necesita -Subred /8, /16 o /24 que contenga la IP del DC; no se presupone el diseno de la zona inversa.' 'Para otros prefijos, revisar manualmente la zona inversa o delegaciones RFC 2317.'
  return
 }
 $octets=([string]$dc.IPv4Address).Split('.')
 $n=[int]($script:net.Prefix / 8)
 $zoneParts=$octets[0..($n-1)]; [array]::Reverse($zoneParts)
 $hostParts=$octets[$n..3];     [array]::Reverse($hostParts)
 $script:rev=($zoneParts -join '.') + '.in-addr.arpa'
 $script:ptrName=$hostParts -join '.'
 $rz=Get-DnsZoneInfo $script:rev
 if($rz.Count){
  $script:revExists=$true
  $z=$rz[0]
  Add-Check 'DNS' "Zona inversa $($script:rev)" $(if($z.IsDsIntegrated -and ([string]$z.DynamicUpdate -eq 'Secure')){'OK'}else{'AVISO'}) ("Integrada={0}; Scope={1}; Actualizacion={2}" -f $z.IsDsIntegrated,$z.ReplicationScope,$z.DynamicUpdate)
 } else {
  Add-Check 'DNS' "Zona inversa $($script:rev)" 'AVISO' 'No existe' 'Opcional pero recomendada para diagnosticos.'
  Show-Guide 'DNS' "Crear zona inversa $($script:rev)" @"
1. Abre Administrador DNS (dnsmgmt.msc) > $env:COMPUTERNAME.
2. Zonas de busqueda inversa > Nueva zona.
3. Principal, almacenada en Active Directory.
4. Ambito: DNS de controladores de este dominio (DomainDnsZones).
5. IPv4, ID de red: $($octets[0..($n-1)] -join '.')
6. Actualizaciones dinamicas: solo seguras.
7. Finaliza y comprueba que existe $($script:rev).
"@
  if($Guiado){
   $script:revExists=(Get-DnsZoneInfo $script:rev).Count -gt 0
   Add-Check 'DNS' "Reverificacion zona inversa $($script:rev)" $(if($script:revExists){'OK'}else{'AVISO'}) $(if($script:revExists){'Zona encontrada'}else{'Sigue sin existir'})
  }
 }
} 'DNS' 'Zona inversa'

# PTR: registro en la zona (servidor) y consulta DNS real, por separado.
if($script:revExists){
 Safe {
  try {
   $records=@(Get-DnsServerResourceRecord -ComputerName 'localhost' -ZoneName $script:rev -RRType Ptr -ErrorAction Stop | Where-Object { $_.HostName -eq $script:ptrName })
  } catch {
   Add-Check 'DNS' "PTR $($dc.IPv4Address) (registro en zona)" 'ERROR' "No se pudo leer la zona $($script:rev): $($_.Exception.Message)"
   return
  }
  if($records.Count){
   $targets=@($records | ForEach-Object { ([string]$_.RecordData.PtrDomainName).TrimEnd('.') })
   Add-Check 'DNS' "PTR $($dc.IPv4Address) (registro en zona)" $(if($targets -contains $fqdn){'OK'}else{'AVISO'}) "Destino=$($targets -join ', '); esperado=$fqdn"
  } else {
   Add-Check 'DNS' "PTR $($dc.IPv4Address) (registro en zona)" 'AVISO' "No existe el registro $($script:ptrName) en $($script:rev)" 'Crear el PTR del DC.'
   Show-Guide 'DNS' "Crear PTR de $($dc.IPv4Address)" @"
1. Administrador DNS > Zonas de busqueda inversa > $($script:rev).
2. Nuevo puntero (PTR), direccion IP del host: $($dc.IPv4Address).
3. Nombre FQDN de destino: $fqdn
4. Comprobar con Resolve-DnsName $($dc.IPv4Address) -Type PTR -Server $($dc.IPv4Address)
"@
  }
 } 'DNS' 'PTR (registro en zona)'
 Safe {
  try {
   $answer=@(Resolve-DnsName -Name $dc.IPv4Address -Type PTR -Server $dc.IPv4Address -DnsOnly -ErrorAction Stop | Where-Object { [string](Get-OptionalProperty $_ 'Type') -eq 'PTR' })
   $names=@($answer | ForEach-Object { ([string](Get-OptionalProperty $_ 'NameHost')).TrimEnd('.') })
   if($names.Count){
    Add-Check 'DNS' "PTR $($dc.IPv4Address) (consulta DNS)" $(if($names -contains $fqdn){'OK'}else{'AVISO'}) "El servidor responde: $($names -join ', '); esperado=$fqdn"
   } else { Add-Check 'DNS' "PTR $($dc.IPv4Address) (consulta DNS)" 'AVISO' 'El servidor responde, pero sin registros PTR.' }
  } catch {
   $err=$_
   switch(Get-DnsFailureKind $err){
    'Fallo'  { Add-Check 'DNS' "PTR $($dc.IPv4Address) (consulta DNS)" 'ERROR' "Fallo de consulta: $($err.Exception.Message)" 'Comprobar que el servicio DNS responde en la IP del DC.' }
    default  { Add-Check 'DNS' "PTR $($dc.IPv4Address) (consulta DNS)" 'AVISO' 'El servidor responde, pero el PTR no existe.' 'Crear el PTR del DC.' }
   }
  }
 } 'DNS' 'PTR (consulta DNS)'
}

Safe {
 $fwdIps=@(Get-ForwarderIPs)
 if($fwdIps.Count -eq 0){
  Add-Check 'DNS' 'Reenviadores' 'AVISO' 'No hay reenviadores configurados; revisar si se usan root hints u otra resolucion.'
 }elseif([string]::IsNullOrWhiteSpace($Reenviador)){
  Add-Check 'DNS' 'Reenviadores' 'INFO' "Configurados=$($fwdIps -join ', '); no se ha indicado un reenviador de referencia."
 }else{
  Add-Check 'DNS' 'Reenviadores' $(if($fwdIps -contains $Reenviador){'OK'}else{'AVISO'}) "Actuales=$($fwdIps -join ', '); esperado=$Reenviador"
 }
 if(-not [string]::IsNullOrWhiteSpace($Reenviador) -and $fwdIps -notcontains $Reenviador){
  Show-Guide 'DNS' "Revisar reenviador DNS $Reenviador" @"
1. Administrador DNS > Propiedades del servidor > Reenviadores > Editar.
2. Si el diseno lo requiere, agrega $Reenviador.
3. Evita que el destino reenvie estas mismas consultas de vuelta al DC (bucle).
4. Comprueba con Get-DnsServerForwarder.
"@
  if($Guiado){
   $fresh=@(Get-ForwarderIPs)
   Add-Check 'DNS' 'Reverificacion reenviadores' $(if($fresh -contains $Reenviador){'OK'}else{'AVISO'}) $(if($fresh.Count){"Actuales=$($fresh -join ', ')"}else{'Sin reenviadores'})
  }
 }
} 'DNS' 'Reenviadores'

$dnsServer=[string](Get-OptionalProperty $dc 'IPv4Address')
$dnsRoot=[string](Get-OptionalProperty $domain 'DNSRoot')
Safe { Test-DnsQuery $dnsRoot 'SOA' $dnsServer } 'DNS' 'Resolucion SOA'
Safe { Test-DnsQuery "_ldap._tcp.dc._msdcs.$dnsRoot" 'SRV' $dnsServer } 'DNS' 'Resolucion SRV'
Safe { Test-DnsQuery 'microsoft.com' 'A' $dnsServer } 'DNS' 'Resolucion externa'

############################ SYSVOL ############################
Safe {
 $shareNames=@(Get-SmbShare | Select-Object -ExpandProperty Name)
 foreach($s in @('SYSVOL','NETLOGON')){Add-Check 'SYSVOL' "Recurso $s" $(if($shareNames -contains $s){'OK'}else{'ERROR'}) "Publicado=$($shareNames -contains $s)"}
 $state=@(Get-CimInstance -Namespace 'root\microsoftdfs' -ClassName DfsrReplicatedFolderInfo -ErrorAction Stop | Where-Object {$_.ReplicatedFolderName -eq 'SYSVOL Share'})
 Add-Check 'SYSVOL' 'Estado DFSR SYSVOL Share' $(if($state.Count -and $state[0].State -eq 4){'OK'}else{'AVISO'}) $(if($state.Count){"State=$($state[0].State) (4=Normal)"}else{'No se ha encontrado SYSVOL Share'})
 $events=@(Get-WinEvent -FilterHashtable @{LogName='DFS Replication';StartTime=(Get-Date).AddHours(-24);Level=2,3} -ErrorAction SilentlyContinue)
 Add-Check 'SYSVOL' 'Advertencias/errores DFSR ultimas 24h' $(if($events.Count){'AVISO'}else{'OK'}) ("Eventos=$($events.Count); IDs=$((@($events | Select-Object -ExpandProperty Id -Unique)) -join ', ')") 'Pueden ser historicos; correlacionar con eventos 4602/6018 y estado DFSR.'
} 'SYSVOL' 'Compartidos y DFSR'

############################ Papelera de reciclaje ############################
Safe {
 $scopes=Get-RecycleBinScopes
 Add-Check 'Recuperacion' 'Papelera AD' $(if($scopes.Count -gt 0){'OK'}else{'AVISO'}) "Ambitos habilitados=$($scopes.Count)" 'Activacion irreversible: gestionar de forma separada con Enterprise Admins.'
 if($scopes.Count -eq 0){
  Show-Guide 'Recuperacion' 'Habilitar papelera de reciclaje de Active Directory' @"
1. Abre Centro de administracion de Active Directory (dsac.exe).
2. Selecciona el dominio o el bosque en el panel izquierdo.
3. En Tareas: Enable Recycle Bin / Habilitar papelera de reciclaje.
4. Lee el aviso: la activacion es IRREVERSIBLE. Confirma solo si procede.
5. Actualiza la consola y comprueba con:
   Get-ADOptionalFeature -Identity 'Recycle Bin Feature' | Format-List Name,EnabledScopes
La opcion en gris puede significar que ya esta activada; valida EnabledScopes.
"@
  if($Guiado){
   $newScopes=Get-RecycleBinScopes
   Add-Check 'Recuperacion' 'Reverificacion papelera' $(if($newScopes.Count -gt 0){'OK'}else{'AVISO'}) "Ambitos habilitados=$($newScopes.Count)"
  }
 }
} 'Recuperacion' 'Papelera AD'
Safe {
 $config=(Get-ADRootDSE).configurationNamingContext
 $obj=Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$config" -Properties tombstoneLifetime,msDS-deletedObjectLifetime
 Add-Check 'Recuperacion' 'Retencion' 'INFO' ("tombstoneLifetime={0}; deletedObjectLifetime={1} (vacio=hereda tombstoneLifetime)" -f (Get-OptionalProperty $obj 'tombstoneLifetime'),(Get-OptionalProperty $obj 'msDS-deletedObjectLifetime'))
} 'Recuperacion' 'Retencion'

############################ Sistema ############################
Safe {
 $w=Get-CimInstance Win32_OperatingSystem
 $lastHotFix=Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
 $kbId=if($lastHotFix){$lastHotFix.HotFixID}else{'ninguno detectado'}
 $kbFecha=if($lastHotFix){$lastHotFix.InstalledOn}else{'-'}
 Add-Check 'Sistema' 'Sistema operativo' 'INFO' ("{0}; build={1}; ultimo KB={2}; fecha KB={3}" -f $w.Caption,$w.BuildNumber,$kbId,$kbFecha)
} 'Sistema' 'Version'
Safe {
 $smb=Get-SmbServerConfiguration
 Add-Check 'Seguridad basica' 'SMBv1 / SMBv2+' $(if(-not $smb.EnableSMB1Protocol -and $smb.EnableSMB2Protocol){'OK'}else{'AVISO'}) ("SMB1={0}; SMB2+={1}" -f $smb.EnableSMB1Protocol,$smb.EnableSMB2Protocol)
} 'Seguridad basica' 'SMB'

############################ Hora (W32Time) ############################
$script:tSrc=$null; $script:tStat=$null; $script:tCfg=$null
Safe {
 $script:tSrc=Invoke-NativeEvidence 'w32tm' @('/query','/source') 'w32tm-source.txt'
 $script:tStat=Invoke-NativeEvidence 'w32tm' @('/query','/status') 'w32tm-status.txt'
 $script:tCfg=Invoke-NativeEvidence 'w32tm' @('/query','/configuration') 'w32tm-configuration.txt'
 $null=Invoke-NativeEvidence 'w32tm' @('/query','/peers') 'w32tm-peers.txt'
 $type=Get-TextValue $script:tCfg.Output 'Type|Tipo'
 $type=if($type){($type -split '\s')[0]}else{$null}
 $expected=if($script:isPdc){'NTP'}else{'NT5DS'}
 $rol=if($script:isPdc){'PDC Emulator: debe sincronizar con una fuente externa fiable (Type=NTP).'}else{'No es PDC: debe sincronizar con la jerarquia del dominio (Type=NT5DS).'}
 if($null -eq $type){ Add-Check 'Hora' 'Rol y tipo de sincronizacion' 'REVISAR' "$rol No se ha podido leer Type; ver w32tm-configuration.txt." }
 else { Add-Check 'Hora' 'Rol y tipo de sincronizacion' $(if($type -eq $expected){'OK'}else{'AVISO'}) "$rol Type actual=$type" }
} 'Hora' 'Configuracion W32Time'
Safe {
 if($null -eq $script:tSrc){ return }
 $src=$script:tSrc.Output.Trim()
 $local=$src -match 'Local CMOS|Free-running|VM IC Time|Reloj CMOS'
 $status=if($script:tSrc.ExitCode -ne 0){'ERROR'}elseif($local){'AVISO'}else{'INFO'}
 $rec=if($local -and $script:isPdc){'El PDC usa el reloj local o del hipervisor: configurar una fuente NTP externa fiable.'}elseif($local){'Este DC deberia sincronizar con la jerarquia del dominio, no con el reloj local.'}else{''}
 Add-Check 'Hora' 'Origen NTP' $status "Origen=$src; ExitCode=$($script:tSrc.ExitCode)" $rec
} 'Hora' 'Origen'
Safe {
 if($null -eq $script:tStat){ return }
 $txt=$script:tStat.Output
 $leap=Get-TextValue $txt 'Leap Indicator|Indicador de salto|Indicador de segundo intercalar'
 $stratum=Get-TextValue $txt 'Stratum|Estrato'
 $last=Get-TextValue $txt 'Last Successful Sync Time|[^:\r\n]*ltima sincronizaci[^:\r\n]*'
 $leapNum=if($leap -and $leap -match '^(\d)'){[int]$Matches[1]}else{$null}
 $stratumNum=if($stratum -and $stratum -match '^(\d+)'){[int]$Matches[1]}else{$null}
 $lastDate=[datetime]::MinValue
 $hasDate=$last -and [datetime]::TryParse($last,[Globalization.CultureInfo]::CurrentCulture,[Globalization.DateTimeStyles]::None,[ref]$lastDate)
 $ageH=if($hasDate){[math]::Round(((Get-Date)-$lastDate).TotalHours,1)}else{$null}
 $detail="Leap=$leap; Stratum=$stratum; Ultima sincronizacion=$last$(if($null -ne $ageH){" (hace $ageH h)"})"
 if($script:tStat.ExitCode -ne 0){ $st='ERROR' }
 elseif($null -eq $leapNum -or $null -eq $stratumNum){ $st='REVISAR'; $detail+='; no se han podido interpretar todos los campos, ver w32tm-status.txt' }
 elseif($leapNum -eq 3 -or $stratumNum -eq 0 -or $stratumNum -ge 16){ $st='AVISO'; $detail+='; el servicio no esta sincronizado' }
 elseif(-not $hasDate){ $st='REVISAR'; $detail+='; fecha de ultima sincronizacion no interpretable' }
 elseif($ageH -gt 24){ $st='AVISO'; $detail+='; mas de 24 h sin sincronizar' }
 else { $st='OK' }
 Add-Check 'Hora' 'Estado de sincronizacion' $st $detail 'Ver w32tm-status.txt y w32tm-peers.txt.'
} 'Hora' 'Estado'
Safe {
 # Diferencia horaria: consulta NTP de solo lectura (w32tm /stripchart), sin cambiar la hora.
 $target=$null
 if($script:isPdc){
  if($script:tSrc -and $script:tSrc.Output -notmatch 'Local CMOS|Free-running|VM IC Time|Reloj CMOS'){ $target=($script:tSrc.Output.Trim() -split '[,\s]')[0] }
 } else { $target=[string](Get-OptionalProperty $domain 'PDCEmulator') }
 if([string]::IsNullOrWhiteSpace($target)){
  Add-Check 'Hora' 'Diferencia horaria' 'REVISAR' 'No hay una referencia valida con la que medir la diferencia (el PDC usa el reloj local).'
  return
 }
 $r=Invoke-NativeEvidence 'w32tm' @('/stripchart',"/computer:$target",'/samples:1','/dataonly') 'w32tm-stripchart.txt'
 $m=[regex]::Matches($r.Output,',\s*([+-]?\d+[.,]\d+)s')
 if($m.Count -eq 0){
  Add-Check 'Hora' "Diferencia horaria con $target" 'REVISAR' 'No se ha podido medir; ver w32tm-stripchart.txt.' 'Comprobar conectividad UDP 123 con la referencia.'
  return
 }
 $offset=[double]::Parse($m[$m.Count-1].Groups[1].Value.Replace(',','.'),[Globalization.CultureInfo]::InvariantCulture)
 $abs=[math]::Abs($offset)
 $st=if($abs -ge 300){'ERROR'}elseif($abs -gt 1){'AVISO'}else{'OK'}
 Add-Check 'Hora' "Diferencia horaria con $target" $st ("Desfase={0:N3} s" -f $offset) 'Kerberos falla con mas de 5 minutos de diferencia; se avisa a partir de 1 s.'
} 'Hora' 'Diferencia horaria'

############################ Servicios ############################
Safe {
 foreach($svc in @('NTDS','DNS','Netlogon','DFSR','KDC','W32Time')){
  $s=Get-Service -Name $svc -ErrorAction Stop
  Add-Check 'Servicios' $svc $(if($s.Status -eq 'Running'){'OK'}else{'AVISO'}) "Estado=$($s.Status); Inicio=$($s.StartType)"
 }
} 'Servicios' 'AD DS, DNS, Kerberos'

############################ DCDIAG ############################
# No se declara OK por ausencia de palabras: si el texto no es concluyente, queda como REVISAR.
foreach($test in @([pscustomobject]@{Name='Advertising';File='dcdiag-advertising.txt'},[pscustomobject]@{Name='Services';File='dcdiag-services.txt'},[pscustomobject]@{Name='SysVolCheck';File='dcdiag-sysvol.txt'},[pscustomobject]@{Name='NetLogons';File='dcdiag-netlogons.txt'},[pscustomobject]@{Name='DNS';File='dcdiag-dns.txt'})){
 Safe {
  $r=Invoke-NativeEvidence 'dcdiag' @("/test:$($test.Name)",'/v') $test.File
  $failed=$r.Output -match '(?im)failed test|no super[oó] la prueba|fall[oó] la prueba'
  $passed=$r.Output -match '(?im)passed test|(?<!no )super[oó] la prueba'
  if($failed){ $st='AVISO'; $txt='El log contiene pruebas no superadas.' }
  elseif($passed -and $r.ExitCode -eq 0){ $st='INFO'; $txt='Superada segun el texto del log (no es una certificacion).' }
  else { $st='REVISAR'; $txt='Resultado no concluyente (idioma o formato no reconocido).' }
  Add-Check 'DCDIAG' $test.Name $st "$txt ExitCode=$($r.ExitCode); Log=$($test.File)" 'Leer el log completo: puede haber advertencias historicas.'
 } 'DCDIAG' $test.Name
}
Safe {
 $r=Invoke-NativeEvidence 'dcdiag' @('/q') 'dcdiag-resumen.txt'
 $st=if($r.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($r.Output)){'AVISO'}else{'INFO'}
 Add-Check 'DCDIAG' 'Resumen /q' $st "ExitCode=$($r.ExitCode); $(if($st -eq 'INFO'){'sin errores listados por /q'}else{'hay salida: revisar dcdiag-resumen.txt'})" 'La ausencia de salida no certifica la salud del DC.'
} 'DCDIAG' 'Resumen'

############################ Replicacion y redundancia ############################
Safe {
 $r=Invoke-NativeEvidence 'repadmin' @('/replsummary') 'repadmin-resumen.txt'
 $r2=Invoke-NativeEvidence 'repadmin' @('/showrepl') 'repadmin-detalle.txt'
 Add-Check 'Redundancia' 'Comandos repadmin' $(if($r.ExitCode -eq 0 -and $r2.ExitCode -eq 0){'INFO'}else{'AVISO'}) "ExitCode resumen=$($r.ExitCode); detalle=$($r2.ExitCode); revisar los logs"
} 'Redundancia' 'Repadmin'
Safe {
 $dcs=@(Get-ADDomainController -Filter *)
 Add-Check 'Redundancia' 'Numero controladores' $(if($dcs.Count -ge 2){'OK'}else{'AVISO'}) ("DC detectados=$($dcs.Count); nombres=$($dcs.HostName -join ', ')") $(if($dcs.Count -ge 2){'Con varios DC, comprobar replicacion y disponibilidad DNS.'}else{'Solo hay un DC: agregar un segundo controlador y verificar DNS y replicacion.'})
} 'Redundancia' 'Numero de DC'

############################ Backups (inventario, bloques independientes) ############################
$script:wbInstalled=$false; $script:wbPolicy=$null; $script:wbSchedule=@(); $script:wbSummary=$null; $script:wbTasks=@(); $script:wbVersionsOK=$false
Safe {
 $backupFeature=Get-WindowsFeature Windows-Server-Backup
 $script:wbInstalled=[bool]$backupFeature.Installed
 Add-Check 'Backups' 'Windows Server Backup' $(if($script:wbInstalled){'OK'}else{'REVISAR'}) "Instalado=$($script:wbInstalled)" 'Si se usa otro software de copias (Veeam, NAKIVO...), revisar en esa herramienta.'
} 'Backups' 'Caracteristica WSB'
Safe {
 $volumes=@(Get-Volume | Where-Object {$_.DriveLetter} | Select-Object DriveLetter,FileSystemLabel,FileSystem,SizeRemaining,Size)
 $volumes | ConvertTo-Json -Depth 4 | Out-File (Join-Path $runDir 'volumenes.json') -Encoding UTF8
} 'Backups' 'Inventario de volumenes'
if($script:wbInstalled){
 Safe {
  $ver=Invoke-NativeEvidence 'wbadmin' @('get','versions') 'wbadmin-versiones.txt'
  $script:wbVersionsOK=($ver.ExitCode -eq 0)
  Add-Check 'Backups' 'Catalogo de versiones wbadmin' 'INFO' "ExitCode=$($ver.ExitCode); ver wbadmin-versiones.txt."
 } 'Backups' 'wbadmin get versions'
 Safe {
  $active=Invoke-NativeEvidence 'wbadmin' @('get','status') 'wbadmin-estado.txt'
  Add-Check 'Backups' 'Copia en curso' 'INFO' "ExitCode=$($active.ExitCode); wbadmin-estado.txt NO representa la programacion."
 } 'Backups' 'wbadmin get status'
 Safe {
  Import-Module WindowsServerBackup -ErrorAction Stop
  $script:wbPolicy=Get-WBPolicy -ErrorAction Stop
  if($null -eq $script:wbPolicy){ Add-Check 'Backups' 'Politica WSB' 'INFO' 'No hay politica de Windows Server Backup configurada.'; return }
  $script:wbPolicy | Format-List * | Out-String | Set-Content (Join-Path $runDir 'wb-policy.txt') -Encoding UTF8
  $script:wbSchedule=Get-NonNullItems (Get-WBSchedule -Policy $script:wbPolicy -ErrorAction Stop)
  Add-Check 'Backups' 'Politica WSB' 'INFO' "Politica encontrada; horarios=$((@($script:wbSchedule | ForEach-Object { $_.ToString('HH:mm') })) -join ', '); ver wb-policy.txt."
 } 'Backups' 'Politica WSB'
 Safe {
  Import-Module WindowsServerBackup -ErrorAction Stop
  $script:wbSummary=Get-WBSummary -ErrorAction Stop
  if($null -ne $script:wbSummary){ $script:wbSummary | Format-List * | Out-String | Set-Content (Join-Path $runDir 'wb-summary.txt') -Encoding UTF8 }
  Add-Check 'Backups' 'Resumen WSB' 'INFO' 'Ver wb-summary.txt.'
 } 'Backups' 'Resumen WSB'
}
Safe {
 $script:wbTasks=@(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'Backup|Copia|AD-' } | Select-Object TaskPath,TaskName,State)
 $script:wbTasks | ConvertTo-Json -Depth 4 | Out-File (Join-Path $runDir 'tareas-backup-candidatas.json') -Encoding UTF8
 Add-Check 'Backups' 'Tareas programadas candidatas' 'INFO' "Tareas candidatas=$($script:wbTasks.Count); una coincidencia en el nombre no confirma el trabajo."
} 'Backups' 'Tareas programadas'

# Tabla de estados: separa lo que el script puede comprobar de lo que exige revision humana.
Safe {
 $sum=$script:wbSummary
 $readyTasks=@($script:wbTasks | Where-Object { [string]$_.State -ne 'Disabled' })
 if($null -ne $script:wbPolicy){ Add-BackupState 'Configurado' 'Si' 'OK' 'Existe una politica de Windows Server Backup.' }
 elseif($script:wbTasks.Count){ Add-BackupState 'Configurado' 'Posible' 'REVISAR' 'No hay politica WSB, pero existen tareas programadas candidatas.' }
 elseif($script:wbInstalled){ Add-BackupState 'Configurado' 'No' 'AVISO' 'WSB instalado sin politica ni tareas candidatas.' }
 else { Add-BackupState 'Configurado' 'No detectado' 'REVISAR' 'WSB no instalado; comprobar si se usa otro software de copias.' }

 if($script:wbSchedule.Count){ Add-BackupState 'Programado' 'Si' 'OK' "Horarios WSB: $((@($script:wbSchedule | ForEach-Object { $_.ToString('HH:mm') })) -join ', ')." }
 elseif($readyTasks.Count){ Add-BackupState 'Programado' 'Posible' 'REVISAR' "Tareas habilitadas candidatas: $(@($readyTasks | ForEach-Object { $_.TaskName }) -join ', ')." }
 else { Add-BackupState 'Programado' 'No detectado' $(if($script:wbInstalled){'AVISO'}else{'REVISAR'}) 'No se ha encontrado una programacion activa.' }

 $lastRun=Get-OptionalProperty $sum 'LastBackupTime'
 $lastOK=Get-OptionalProperty $sum 'LastSuccessfulBackupTime'
 $hr=Get-OptionalProperty $sum 'LastBackupResultHR'
 if(Test-ValidDate $lastRun){ Add-BackupState 'Ejecutado' 'Si' 'OK' "Ultimo intento: $lastRun." }
 else { Add-BackupState 'Ejecutado' 'No detectado' $(if($script:wbInstalled){'AVISO'}else{'REVISAR'}) 'WSB no registra ningun intento de copia.' }

 if((Test-ValidDate $lastOK) -and $hr -eq 0){
  $ageD=[math]::Round(((Get-Date)-$lastOK).TotalDays,1)
  Add-BackupState 'Correcto' $(if($ageD -le 7){'Si'}else{'Antiguo'}) $(if($ageD -le 7){'OK'}else{'AVISO'}) "Ultima copia correcta: $lastOK (hace $ageD dias)."
 } elseif(Test-ValidDate $lastRun){
  Add-BackupState 'Correcto' 'No' 'AVISO' "El ultimo intento no termino bien (HR=$hr). $([string](Get-OptionalProperty $sum 'DetailedMessage'))"
 } else { Add-BackupState 'Correcto' 'Desconocido' 'REVISAR' 'Sin datos de ejecucion en WSB.' }

 $nver=Get-OptionalProperty $sum 'NumberOfVersions'
 if($nver -and $nver -gt 0){ Add-BackupState 'Recuperable' 'No verificado' 'REVISAR' "Hay $nver versiones en el catalogo, pero el script no comprueba su contenido." }
 else { Add-BackupState 'Recuperable' 'No verificado' 'REVISAR' 'No hay versiones en el catalogo WSB o no se han podido leer.' }

 Add-BackupState 'Restauracion probada' 'Requiere prueba manual' 'AVISO' 'Ningun script puede confirmarlo: documentar una restauracion de System State en un entorno aislado.'
} 'Backups' 'Tabla de estados'

############################ Asistente de backups (solo planificacion) ############################
if($Guiado){
 Write-Host "`n==== ASISTENTE DE BACKUPS (solo instrucciones; NO crea tareas ni ejecuta copias) ====" -ForegroundColor Cyan
 Write-Host 'Cada modalidad puede disponer de un destino y horario independientes.'
 Write-Host 'Las tres copias se solapan parcialmente y pueden requerir herramientas/destinos diferentes.'
 foreach($tipo in @('System State','Bare Metal Recovery','Full Server')){
  $eleccion=(Read-Host "¿Quieres documentar la configuracion de ${tipo}? [S/N]")
  if($eleccion -notmatch '^[sS]') { $script:backups.Add([pscustomobject]@{Tipo=$tipo;Decision='Omitido';Destino='';Frecuencia='';Hora='';Retencion='';Verificacion='No verificado'}); continue }
  $dest=Read-Host "Destino previsto para $tipo (p.ej. D: o ruta UNC; no se utiliza automaticamente)"
  $freq=Read-Host 'Frecuencia prevista (diario/semanal/manual)'
  $hora=Read-Host 'Hora prevista (HH:mm)'
  $ret=Read-Host 'Retencion prevista (p.ej. 30 dias; requiere estrategia compatible)'
  $script:backups.Add([pscustomobject]@{Tipo=$tipo;Decision='Planificado, no configurado por script';Destino=$dest;Frecuencia=$freq;Hora=$hora;Retencion=$ret;Verificacion='Pendiente de validar una restauracion'})
  switch($tipo){
  'System State' {$ex="Con Windows Server Backup instalado y destino VALIDADO, ejecutar una copia puntual: wbadmin start systemstatebackup -backupTarget:<destino>. Para automatizar SOLO System State, crear una tarea del Programador con privilegios SYSTEM y revisar cuenta, destino, cuotas y eventos. No supone imagen completa."}
  'Bare Metal Recovery' {$ex="En Windows Server Backup > Backup Once/Backup Schedule > Custom > Add Items > Bare metal recovery, revisar que incluye todos los volumenes criticos. Elegir almacenamiento compatible. ADVERTENCIA: la opcion de disco dedicado puede FORMATEAR el destino. No pulsar Confirmar sin revisar."}
  'Full Server' {$ex="En Windows Server Backup > Backup Once/Backup Schedule > Full server. Revisar volumenes incluidos y EXCLUIR el destino. En discos dedicados la herramienta puede FORMATEAR. No iniciar sin confirmar componentes y capacidad."}
  }
  Show-Guide 'Backups' "Configurar $tipo con destino independiente" @"
$ex
Destino previsto: $dest
Frecuencia: $freq; hora: $hora; retencion solicitada: $ret.
Tras la copia: comprobar historial y versiones con 'wbadmin get versions', registros Microsoft-Windows-Backup y, en un entorno aislado, realizar una prueba de recuperacion.
Advertencia: un disco local en el mismo servidor no protege frente a perdida del servidor, robo o ransomware. Tres carpetas en un disco NO son tres destinos independientes.
La retencion exacta y la coexistencia de las modalidades dependen del tipo de destino y del software elegido. Este asistente no garantiza ni aplica la retencion.
"@
 }
}

############################ Pendientes no automatizables ############################
Add-Check 'Pendientes' 'Firewall DNS y bucles de reenvio' 'INFO' 'La deteccion de bucles de reenviadores no se automatiza.' 'Confirmar que el resolvedor externo (firewall/router) no reenvia consultas generales de vuelta al DC.'
Add-Check 'Pendientes' 'Eventos DCOM hacia dispositivos no Windows' 'INFO' 'Revisar eventos DCOM 10009 si aparecen; diagnosticar el host de destino.' 'No abrir RPC/DCOM hacia un resolvedor DNS solo para eliminar advertencias.'
Add-Check 'Pendientes' 'Versiones y parches de seguridad' 'INFO' 'La fecha del ultimo KB no garantiza estar actualizado.' 'Verificar Windows Update y el ultimo parche aplicable.'

############################ Informes ############################
$meta=[pscustomobject]@{
 Fecha=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'); Host=$env:COMPUTERNAME
 Dominio=if($domain){$domain.DNSRoot}else{'no disponible'}
 Bosque=if($forest){$forest.Name}else{'no disponible'}
 Modo=if($Guiado){'Guiado manual, sin cambios automaticos'}else{'Solo lectura'}
 Carpeta=$runDir
}
$payload=[pscustomobject]@{Metadata=$meta;Resultados=@($script:checks.ToArray());Cambios=@();Guias=@($script:guides.ToArray());EstadoBackups=@($script:wbState.ToArray());PlanBackups=@($script:backups.ToArray())}
$payload | ConvertTo-Json -Depth 8 | Out-File -FilePath (Join-Path $runDir 'informe.json') -Encoding UTF8

$reportLines=@("AUDITORIA DE ACTIVE DIRECTORY", "Fecha: $($meta.Fecha)","Servidor: $($meta.Host)","Dominio: $($meta.Dominio)","Modo: $($meta.Modo)","Carpeta de evidencias: $runDir",'')
$reportLines += 'Estados: OK correcto | AVISO revisar o corregir | ERROR fallo | INFO informativo | REVISAR requiere revision humana'
$reportLines += ''
foreach($row in $checks){$reportLines += "[$($row.Estado)] $($row.Area) / $($row.Prueba): $($row.Detalle)"; if($row.Recomendacion){$reportLines += "    Accion: $($row.Recomendacion)"}}
$reportLines += ''; $reportLines += 'ESTADO DE LAS COPIAS DE SEGURIDAD:'
foreach($s in $script:wbState){$reportLines += "$($s.Estado): $($s.Valor) - $($s.Detalle)"}
$reportLines += ''; $reportLines += 'GUIAS MANUALES MOSTRADAS:'
if($guides.Count){foreach($g in $guides){$reportLines += "[$($g.Respuesta)] $($g.Tarea)"; $reportLines += $g.Instrucciones }}else{$reportLines += 'Ninguna'}
$reportLines += ''; $reportLines += 'PLANIFICACION DE BACKUPS (NO configurada automaticamente):'
if($backups.Count){foreach($b in $backups){$reportLines += "$($b.Tipo): $($b.Decision); destino=$($b.Destino); frecuencia=$($b.Frecuencia); hora=$($b.Hora); retencion=$($b.Retencion)"}}else{$reportLines += 'No documentada (solo en modo -Guiado)'}
$reportLines += ''; $reportLines += 'CAMBIOS AUTOMATICOS: NINGUNO (solo lectura)'
$reportLines += ''; $reportLines += 'NOTA: Informacion de auditoria, no certificado de cumplimiento ni garantia de recuperabilidad.'
$reportLines | Out-File -FilePath (Join-Path $runDir 'informe.txt') -Encoding UTF8

$rows=foreach($r in $checks){
 "<tr><td>$(Encode $r.Area)</td><td>$(Encode $r.Prueba)</td><td class='$(Encode $r.Estado)'>$(Encode $r.Estado)</td><td>$(Encode $r.Detalle)</td><td>$(Encode $r.Recomendacion)</td></tr>"
}
$wbRows=foreach($s in $script:wbState){ "<tr><td>$(Encode $s.Estado)</td><td>$(Encode $s.Valor)</td><td>$(Encode $s.Detalle)</td></tr>" }
$html=@"
<!doctype html><html lang='es'><head><meta charset='utf-8'><title>Auditoria Active Directory</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:1300px;margin:40px auto;color:#162334;padding:0 20px}h1{border-bottom:3px solid #254e72;padding-bottom:15px}table{border-collapse:collapse;width:100%;font-size:13px;margin-bottom:24px}th,td{border:1px solid #dae1e8;text-align:left;padding:9px;vertical-align:top}th{background:#eaf0f6}.OK{color:#0b773a;font-weight:700}.AVISO{color:#9f5b00;font-weight:700}.ERROR{color:#b52323;font-weight:700}.INFO{color:#315e86;font-weight:700}.REVISAR{color:#7a2e8e;font-weight:700}.note{padding:15px;background:#f1f5fa;margin:20px 0}pre{white-space:pre-wrap;word-break:break-word;background:#f7f9fb;padding:12px;border:1px solid #dae1e8}</style></head><body>
<h1>Auditoria de Active Directory</h1><p><strong>Fecha:</strong> $(Encode $meta.Fecha) &nbsp; <strong>DC:</strong> $(Encode $meta.Host) &nbsp; <strong>Dominio:</strong> $(Encode $meta.Dominio)</p>
<div class='note'>Modo: $(Encode $meta.Modo). Informe de comprobacion, no sustituye copias de seguridad, pruebas de restauracion ni revision experta.<br>Estados: <span class='OK'>OK</span> correcto &middot; <span class='AVISO'>AVISO</span> revisar o corregir &middot; <span class='ERROR'>ERROR</span> fallo &middot; <span class='INFO'>INFO</span> informativo &middot; <span class='REVISAR'>REVISAR</span> requiere revision humana.</div>
<table><thead><tr><th>Area</th><th>Comprobacion</th><th>Estado</th><th>Detalle</th><th>Recomendacion</th></tr></thead><tbody>$($rows -join "`n")</tbody></table>
<h2>Estado de las copias de seguridad</h2><table><thead><tr><th>Estado</th><th>Valor</th><th>Detalle</th></tr></thead><tbody>$($wbRows -join "`n")</tbody></table>
<h2>Backups planificados (sin cambios automaticos)</h2><pre>$(Encode (($backups | ForEach-Object {"$($_.Tipo): $($_.Decision); destino=$($_.Destino); frecuencia=$($_.Frecuencia); hora=$($_.Hora); retencion=$($_.Retencion)"}) -join "`n"))</pre><h2>Guias manuales mostradas</h2><pre>$(Encode (($guides | ForEach-Object {"[$($_.Respuesta)] $($_.Tarea)`n$($_.Instrucciones)"}) -join "`n`n"))</pre><h2>Cambios automaticos</h2><p>Ninguno: modo siempre de solo lectura.</p>
<h2>Evidencias</h2><p>Consultar los logs de DCDIAG, repadmin, W32Time y Windows Server Backup guardados junto al informe.</p></body></html>
"@
$html | Out-File -FilePath (Join-Path $runDir 'informe.html') -Encoding UTF8
Write-Host "`nFINALIZADO. Informes HTML, TXT, JSON y logs en: $runDir" -ForegroundColor Green
$cnt={ param($e) @($checks | Where-Object Estado -eq $e).Count }
Write-Host ('OK={0}  AVISO={1}  ERROR={2}  INFO={3}  REVISAR={4}' -f (& $cnt 'OK'),(& $cnt 'AVISO'),(& $cnt 'ERROR'),(& $cnt 'INFO'),(& $cnt 'REVISAR'))
