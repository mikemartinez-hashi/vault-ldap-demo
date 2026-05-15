<powershell>
# ============================================================
# Active Directory Domain Services Bootstrap
# Phase 1 (first boot): Install AD DS role, configure forest
# Phase 2 (post-reboot): Create OUs and service accounts
# ============================================================

# Terraform templatefile-injected values
$LdapDomain    = "${ldap_domain}"
$LdapOrg       = "${ldap_organization}"
$LdapAdminPass = "${ldap_admin_password}"
$LdapBaseDn    = "${ldap_base_dn}"
$NetbiosName   = "${ldap_netbios_name}"

$PhaseFile = "C:\ldap-bootstrap-phase.txt"
$LogFile   = "C:\ldap-bootstrap.log"

function Write-Log {
    param([string]$Msg)
    $Line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg"
    Add-Content -Path $LogFile -Value $Line -ErrorAction SilentlyContinue
    Write-Output $Line
}

$Phase = if (Test-Path $PhaseFile) { (Get-Content $PhaseFile).Trim() } else { "1" }

Write-Log "============================================================"
Write-Log "AD DS Bootstrap - Phase $Phase"
Write-Log "Domain  : $LdapDomain"
Write-Log "Org     : $LdapOrg"
Write-Log "Base DN : $LdapBaseDn"
Write-Log "============================================================"

# ============================================================
# PHASE 1 - Install AD DS and trigger domain creation (reboots)
# ============================================================
if ($Phase -eq "1") {
    Write-Log "Phase 1: Installing AD-Domain-Services and DNS roles..."
    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools -NoRestart

    # Write phase marker BEFORE the reboot so Phase 2 runs after restart
    Set-Content -Path $PhaseFile -Value "2"
    Write-Log "Phase marker written. Configuring forest and rebooting..."

    $SafePwd = ConvertTo-SecureString $LdapAdminPass -AsPlainText -Force

    Import-Module ADDSDeployment
    Install-ADDSForest `
        -DomainName            $LdapDomain `
        -DomainNetbiosName     $NetbiosName `
        -SafeModeAdministratorPassword $SafePwd `
        -InstallDns:$true `
        -NoRebootOnCompletion:$false `
        -Force:$true

    # System reboots here - nothing below runs on this boot
}

# ============================================================
# PHASE 2 - Post-reboot: create OUs and service accounts
# ============================================================
elseif ($Phase -eq "2") {
    Write-Log "Phase 2: Waiting for AD DS to become ready..."
    Start-Sleep -Seconds 60

    # Poll until AD Web Services (ADWS) responds
    $MaxWait = 180
    $Elapsed = 0
    while ($Elapsed -lt $MaxWait) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            Get-ADDomain -ErrorAction Stop | Out-Null
            Write-Log "AD DS is ready after $Elapsed s."
            break
        } catch {
            Write-Log "AD DS not ready yet ($Elapsed s elapsed) - retrying in 10s..."
            Start-Sleep -Seconds 10
            $Elapsed += 10
        }
    }

    # Create ServiceAccounts OU
    try {
        New-ADOrganizationalUnit `
            -Name "ServiceAccounts" `
            -Path $LdapBaseDn `
            -Description "$LdapOrg - Service accounts managed by HCP Vault" `
            -ErrorAction Stop
        Write-Log "Created OU: ou=ServiceAccounts,$LdapBaseDn"
    } catch {
        Write-Log "OU may already exist: $_"
    }

    # Create service accounts
    # AD requires complex passwords (upper+lower+number+symbol, min 7 chars)
    # Vault will rotate these immediately after static roles are created.
    $SvcPwd = ConvertTo-SecureString $LdapAdminPass -AsPlainText -Force

    foreach ($SvcName in @("svc-app1", "svc-app2")) {
        try {
            New-ADUser `
                -Name              $SvcName `
                -SamAccountName    $SvcName `
                -UserPrincipalName "$SvcName@$LdapDomain" `
                -Path              "OU=ServiceAccounts,$LdapBaseDn" `
                -AccountPassword   $SvcPwd `
                -PasswordNeverExpires $true `
                -Enabled           $true `
                -Description       "Service account managed by HCP Vault LDAP secrets engine" `
                -ErrorAction Stop
            Write-Log "Created service account: CN=$SvcName,OU=ServiceAccounts,$LdapBaseDn"
        } catch {
            Write-Log "Account $SvcName may already exist: $_"
        }
    }

    # Allow LDAP/LDAPS through Windows Firewall
    try {
        New-NetFirewallRule -DisplayName "LDAP-389"  -Direction Inbound -Protocol TCP -LocalPort 389  -Action Allow -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName "LDAPS-636" -Direction Inbound -Protocol TCP -LocalPort 636  -Action Allow -ErrorAction SilentlyContinue
        Write-Log "Firewall rules for LDAP 389/636 confirmed."
    } catch {
        Write-Log "Firewall rule note: $_"
    }

    # ---- Configure LDAPS certificate ----
    # AD needs a cert in the Personal store to enable port 636 (LDAPS).
    # The cert is picked up ONLY after a full DC reboot - not just an NTDS restart.
    Write-Log "Creating self-signed LDAPS certificate..."
    try {
        $CertParams = @{
            Subject           = "CN=$env:COMPUTERNAME"
            DnsName           = @($env:COMPUTERNAME, $LdapDomain, "localhost")
            CertStoreLocation = "Cert:\LocalMachine\My"
            KeyLength         = 2048
            KeyAlgorithm      = "RSA"
            HashAlgorithm     = "SHA256"
            NotAfter          = (Get-Date).AddYears(5)
            KeyUsage          = @("DigitalSignature", "KeyEncipherment")
            TextExtension     = @("2.5.29.37={text}1.3.6.1.5.5.7.3.1")
        }
        $Cert = New-SelfSignedCertificate @CertParams
        Write-Log "LDAPS cert created: $($Cert.Thumbprint)"
    } catch {
        Write-Log "WARNING: cert creation failed: $_"
    }

    # Set Phase 3 BEFORE rebooting so the next boot activates LDAPS verification
    Set-Content -Path $PhaseFile -Value "3"
    Write-Log "Phase 3 on next boot will confirm LDAPS on port 636. Rebooting..."
    Restart-Computer -Force
}

# ============================================================
# PHASE 3 - Post-cert-reboot: verify LDAPS is active
# ============================================================
elseif ($Phase -eq "3") {
    Write-Log "Phase 3: Verifying LDAPS is active after cert reboot..."
    Start-Sleep -Seconds 60

    $MaxWait = 120
    $Elapsed = 0
    $LdapsReady = $false
    while ($Elapsed -lt $MaxWait) {
        $Test = Test-NetConnection -ComputerName localhost -Port 636 -WarningAction SilentlyContinue
        if ($Test.TcpTestSucceeded) {
            Write-Log "LDAPS is active on port 636 after $Elapsed s."
            $LdapsReady = $true
            break
        }
        Write-Log "Port 636 not ready yet ($Elapsed s) - retrying in 15s..."
        Start-Sleep -Seconds 15
        $Elapsed += 15
    }

    if (-not $LdapsReady) {
        Write-Log "WARNING: Port 636 did not come up after $MaxWait s."
    }

    Set-Content -Path $PhaseFile -Value "done"
    Write-Log "============================================================"
    Write-Log "AD DS Bootstrap COMPLETE"
    Write-Log "Domain   : $LdapDomain"
    Write-Log "Accounts : svc-app1, svc-app2 in OU=ServiceAccounts,$LdapBaseDn"
    Write-Log "LDAPS    : port 636 active = $LdapsReady"
    Write-Log "============================================================"
}

elseif ($Phase -eq "done") {
    Write-Log "Bootstrap already complete - no action needed."
}
</powershell>
<persist>true</persist>
