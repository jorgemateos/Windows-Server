# requires -RunAsAdministrator
# Set-ExecutionPolicy -Scope LocalMachine Unrestricted -force


# Script de primera configuracion basica tras la instalacion de windows server
#  * Partes del Scipt
#    - Cambiar nombre de Hostname
#    - Cambiar inicio automatico del Administrador del Servidor
#    - Habilitar RDP
#    - Cambiar IP
#    - Reiniciar Servidor

Clear-Host

###################### Hostname ######################
# Muestra el nombre del host
    $hostname = hostname
    Write-Host "El nombre actual del host es: $hostname"

# Pregunta al usuario si quiere cambiar el nombre del host
    $respuesta = Read-Host "¿Quieres cambiar el nombre del host? (s/n)"

while ($respuesta -ne 's' -and $respuesta -ne 'n') {
    Clear-Host
    Write-Host "El nombre actual del host es: $hostname"

    $respuesta = Read-Host "¿Quieres cambiar el nombre del host? (s/n)"
}

if ($respuesta -eq 's') {
    Clear-Host
    Write-Host "El nombre actual del host es: $hostname"

    $nuevoNombre = Read-Host "Introduce el nuevo nombre del host"
    # Cambia el nombre del host sin reiniciar
    Rename-Computer -NewName $nuevoNombre -Restart:$false
    $Reinicio = 1
    ##Write-Host "El nombre del host ha sido cambiado a: $nuevoNombre"
}

        
###################### Optimizadores ######################
# Deshabilitar el inicio automatico del Administrador del Servidor para sesiones de escritorio remoto
    Set-ItemProperty -Path 'HKLM:\Software\Microsoft\ServerManager' -Name 'DoNotOpenServerManagerAtLogon' -Value 1


###################### Escritorio remoto (RDP) ######################
# Verificar y cambiar la configuracion del Escritorio Remoto
    $rdp = (Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections

    if ($rdp -eq 0) {
        Clear-Host
        Write-Host "El Escritorio Remoto esta habilitado."
        $response = Read-Host "¿Quieres deshabilitarlo? (s/n)"
        while ($response -ne 's' -and $response -ne 'n') {
            Clear-Host
            Write-Host "El Escritorio Remoto esta habilitado."

            $response = Read-Host "¿Quieres deshabilitarlo? (s/n)"
        }
        if ($response -eq 's') {
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -value 1

            $Reinicio = 1
        }
    } else {
        Clear-Host
        Write-Host "El Escritorio Remoto esta deshabilitado."
        $response = Read-Host "¿Quieres habilitarlo? (s/n)"
        while ($response -ne 's' -and $response -ne 'n') {
            Clear-Host
            Write-Host "El Escritorio Remoto esta deshabilitado."
            $response = Read-Host "¿Quieres habilitarlo? (s/n)"
        }
        if ($response -eq 's') {
            Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -value 0
            #Write-Host "El Escritorio Remoto ha sido habilitado."
            $Reinicio = 1

            Clear-Host
            $response = Read-Host "¿Quieres cambiar el numero de puerto del Escritorio Remoto? (s/n)"
            while ($response -ne 's' -and $response -ne 'n') {
                Clear-Host
                $response = Read-Host "¿Quieres cambiar el numero de puerto del Escritorio Remoto? (s/n)"
            }
            if ($response -eq 's') {
                Clear-Host
                $port = Read-Host "Introduce el puerto del escritorio remoto:"
                Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "PortNumber" -value $port

                # Añadir regla Firewall para el escritorio remoto (RDP)
                New-NetFirewallRule -DisplayName 'RDP' -Profile 'Any' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port
                New-NetFirewallRule -DisplayName 'RDP' -Profile 'Any' -Direction Inbound -Action Allow -Protocol UDP -LocalPort $port
            }
        }
    }


###################### Cambiar ip estatica ######################
Clear-Host

function Show-tablainterfaces{
    $resultados = @()
    $interfaces = Get-NetAdapter
    foreach ($interfaz in $interfaces) {
        $resultado = New-Object PSObject
        $resultado | Add-Member -MemberType NoteProperty -Name "Interfaz" -Value $interfaz.InterfaceAlias
        $dhcp = Get-NetIPInterface -InterfaceAlias $interfaz.InterfaceAlias | Select-Object -ExpandProperty Dhcp
        $resultado | Add-Member -MemberType NoteProperty -Name "DHCP" -Value $dhcp
        $configuracionIP = Get-NetIPAddress -InterfaceIndex $interfaz.ifIndex | Where-Object { $_.AddressFamily -eq 'IPv4' }
        foreach ($config in $configuracionIP) {
            $resultado | Add-Member -MemberType NoteProperty -Name "Direccion IP" -Value $config.IPAddress
            $resultado | Add-Member -MemberType NoteProperty -Name "Subnet mask" -Value $config.PrefixLength
            $resultado | Add-Member -MemberType NoteProperty -Name "Gateway" -Value (Get-NetRoute -InterfaceIndex $config.ifIndex | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } | Select-Object -ExpandProperty NextHop)
        }
        $resultado | Add-Member -MemberType NoteProperty -Name "Servidores DNS" -Value (Get-DnsClientServerAddress -InterfaceIndex $interfaz.ifIndex | Where-Object { $_.AddressFamily -eq 'IPv4' } | Select-Object -ExpandProperty ServerAddresses)
        $resultados += $resultado
    }
    $resultados | Format-Table
}

Show-tablainterfaces
$respuesta = Read-Host "¿Quieres modificar alguna interfaz? (s/n)"
while ($respuesta -ne 's' -and $respuesta -ne 'n') {
    Clear-host
    Show-tablainterfaces

    $respuesta = Read-Host "¿Quieres modificar alguna interfaz? (s/n)"
}

if ($respuesta -eq 's') {
    Clear-host
    Show-tablainterfaces

    $interfazAModificar = Read-Host "¿Que interfaz quieres modificar?"
    $interfaz = Get-NetAdapter | Where-Object { $_.InterfaceAlias -eq $interfazAModificar }
    $dhcp = Get-NetIPInterface -InterfaceAlias $interfaz.InterfaceAlias | Select-Object -ExpandProperty Dhcp
    if ($dhcp -eq 'Enabled') {
        Clear-Host
        $respuesta = Read-Host "DHCP esta habilitado en esta interfaz. ¿Quieres cambiar esta interfaz a estatica? (s/n)"
        while ($respuesta -ne 's' -and $respuesta -ne 'n') {

        Clear-Host
        $respuesta = Read-Host "DHCP esta habilitado en esta interfaz. ¿Quieres cambiar esta interfaz a estatica? (s/n)"
    }
        if ($respuesta -eq 's') {
            # Aqui deberias añadir el codigo para cambiar la interfaz a estatica
            $ip = Read-Host "Introduce la direccion IP que quieres asignar a la interfaz"
            $subnet = Read-Host "Introduce la mascara de subred"
            $gateway = Read-Host "Introduce la puerta de enlace"
            $dns = Read-Host "Introduce las direcciones DNS (separadas por comas si son varias)"

            # Elimina la configuracion IP actual
            Remove-NetIPAddress -InterfaceAlias $interfazAModificar -Confirm:$false

            # Establece la nueva configuracion IP
            New-NetIPAddress -InterfaceAlias $interfazAModificar -IPAddress $ip -PrefixLength $subnet -DefaultGateway $gateway

            # Establece las nuevas direcciones DNS
            Set-DnsClientServerAddress -InterfaceAlias $interfazAModificar -ServerAddresses $dns.Split(',')
        }
    } else {
        $respuesta = Read-Host "DHCP no esta habilitado en esta interfaz. ¿Quieres habilitar DHCP en esta interfaz? (s/n)"
        while ($respuesta -ne 's' -and $respuesta -ne 'n') {
            $respuesta = Read-Host "Por favor, responde con 's' para si o 'n' para no. ¿Quieres habilitar DHCP en esta interfaz?"
    }
        if ($respuesta -eq 's') {
            # Aqui deberias añadir el codigo para habilitar DHCP en la interfaz seleccionada
            Set-NetIPInterface -InterfaceAlias $interfazAModificar -Dhcp Enabled
        }
    }
}


###################### Reiniciar Servidor al Terminar ######################
    if ($Reinicio -eq 1){
        Restart-Computer -Force
    }
