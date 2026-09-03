# Installs VMware Tools during Windows specialize, from a mounted Tools ISO or by direct download if none is attached.
[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Proxy server URL to route the VMware Tools download listing and installer fetch through, for example http://proxy.example.com:8080. Omit to use the machine's default network configuration.")]
    [ValidateScript({
        $ParsedUri = $null
        if (-not [Uri]::TryCreate($_, [UriKind]::Absolute, [ref]$ParsedUri)) {
            throw "The value '$_' is not a valid absolute URI."
        }
        $true
    })]
    [string]$ProxyUrl
)

# Splatted onto every Invoke-WebRequest call so -ProxyUrl, when given, is the only place proxy routing is decided
$script:WebRequestProxyArgs = @{}
if ($ProxyUrl) {
    $script:WebRequestProxyArgs['Proxy'] = $ProxyUrl
}

& {
	# VMware's documented silent switches: /S for the bootstrapper, /v passes the rest to the MSI.
	$silent = '/S /v"/qn REBOOT=R"';

	# Preferred path: a hypervisor mounted Tools ISO, identified by a setup.exe whose product name is 'VMware Tools'.
	foreach( $letter in 'DEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray() ) {
		$exe = "${letter}:\setup.exe";
		if( ( Get-Item -LiteralPath $exe -ErrorAction 'SilentlyContinue' | Select-Object -ExpandProperty 'VersionInfo' | Select-Object -ExpandProperty 'ProductName' ) -eq 'VMware Tools' ) {
			'Installing VMware Tools from {0}.' -f $exe;
			Start-Process -FilePath $exe -ArgumentList $silent -Wait;
			return;
		}
	}
	'VMware Tools image (windows.iso) is not attached to this VM. Falling back to a direct download.';

	# The drive scan also comes up empty on physical hardware, so confirm this really is a VM before downloading anything.
	if( ( Get-CimInstance -ClassName 'Win32_ComputerSystem' ).Manufacturer -notmatch 'VMware' ) {
		'This is not a VMware virtual machine, so nothing will be downloaded.';
		return;
	}

	$base = 'https://packages.vmware.com/tools/releases/latest/windows/x64/';
	[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12;
	$ProgressPreference = 'SilentlyContinue';

	# First logon can start before DHCP settles, so keep retrying the listing for about three minutes.
	$name = $null;
	for( $i = 1; $i -le 18 -and -not $name; $i++ ) {
		try {
			$name = @( ( Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 15 @script:WebRequestProxyArgs ).Links.href | Where-Object { $_ -like '*.exe' -and $_ -notmatch '[\\/:]' } )[0];
		}
		catch {
			'Attempt {0} to read {1} failed: {2}' -f $i, $base, $_.Exception.Message;
		}
		if( -not $name ) {
			Start-Sleep -Seconds 10;
		}
	}
	if( -not $name ) {
		'Could not reach the VMware download site. VMware Tools was not installed.';
		return;
	}

	$file = Join-Path -Path $env:TEMP -ChildPath $name;
	try {
		'Downloading {0}.' -f $name;
		Invoke-WebRequest -Uri ( $base + $name ) -OutFile $file -UseBasicParsing @script:WebRequestProxyArgs;
		# Never execute the download unless Authenticode says it is intact and signed by VMware/Broadcom.
		$sig = Get-AuthenticodeSignature -LiteralPath $file;
		if( $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'VMware|Broadcom' ) {
			'Refusing to run {0}: signature status is {1}, signer is {2}.' -f $name, $sig.Status, $sig.SignerCertificate.Subject;
			return;
		}
		'Installing {0}.' -f $name;
		Start-Process -FilePath $file -ArgumentList $silent -Wait;
	}
	catch {
		'Download or installation failed: {0}' -f $_.Exception.Message;
	}
	finally {
		Remove-Item -LiteralPath $file -Force -ErrorAction 'SilentlyContinue';
	}
} *>&1 | Out-String -Width 1KB -Stream >> 'C:\Windows\Setup\Scripts\VMwareTools.log';