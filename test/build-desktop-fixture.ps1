param([Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'desktop-fixture.cs') -ReferencedAssemblies System.Windows.Forms,System.Drawing -OutputAssembly $OutputPath -OutputType WindowsApplication
