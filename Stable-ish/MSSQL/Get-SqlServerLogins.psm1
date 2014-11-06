function Get-SqlServerLogins
{
    <#
        .SYNOPSIS
        This script can be used to obtain a list of all logins from a SQL Server as a sysadmin or user with the PUBLIC role.

        .DESCRIPTION
        This script can be used to obtain a list of all logins from a SQL Server as a sysadmin or user with the PUBLIC role.
        Selecting all of the logins from the master..syslogins table is not possible using a login with only the PUBLIC role.
        However, it is possible to quickly enumerate SQL Server logins using the SUSER_SNAME function by fuzzing the principal_id
        number parameter, because the principal ids assigned to logins are incremental.  Once a user list is enumerated they can 
        be verified via sp_defaultdb error ananlysis.  This is important, because not all of sid resolved will be SQL logins.

        .EXAMPLE
        Below is an example of how to enumerate logins from a SQL Server using the current Windows user context or "trusted connection".
        PS C:\> Get-SqlServerLogins -SQLServerInstance "SQLSERVER1\SQLEXPRESS" 
    
        .EXAMPLE
        Below is an example of how to enumerate logins from a SQL Server using alternative domain credentials.
        PS C:\> Get-SqlServerLogins -SQLServerInstance "SQLSERVER1\SQLEXPRESS" -SqlUser domain\user -SqlPass MyPassword!

        .EXAMPLE
        Below is an example of how to enumerate logins from a SQL Server using a SQL Server login".
        PS C:\> Get-SqlServerLogins -SQLServerInstance "SQLSERVER1\SQLEXPRESS" -SqlUser MyUser -SqlPass MyPassword!

        .EXAMPLE
        Below is an example of how to enumerate logins from a SQL Server using a SQL Server login".
        PS C:\> Get-SqlServerLogins -SQLServerInstance "SQLSERVER1\SQLEXPRESS" -SqlUser MyUser -SqlPass MyPassword! | Export-Csv c:\temp\sqllogins.csv -NoTypeInformation

        .EXAMPLE
        Below is an example of how to enumerate logins from a SQL Server using a SQL Server login with non default fuzznum".
        PS C:\> Get-SqlServerLogins -SQLServerInstance "SQLSERVER1\SQLEXPRESS" -SqlUser MyUser -SqlPass MyPassword! -FuzzNum 500
    
        .NOTES
        Author: Scott Sutherland - 2014, NetSPI
        Version: Get-SqlServerLogins v1.0
        Comments: This should work on SQL Server 2005 and Above.

    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false,
        HelpMessage = 'Set SQL or Domain Login username.')]
        [string]$SqlUser,
        [Parameter(Mandatory = $false,
        HelpMessage = 'Set SQL or Domain Login password.')]
        [string]$SqlPass,   
        [Parameter(Mandatory = $true,
        HelpMessage = 'Set target SQL Server instance.')]
        [string]$SqlServerInstance,
        [Parameter(Mandatory = $false,
        HelpMessage = 'Max SID to fuzz.')]
        [string]$FuzzNum
    )

    #------------------------------------------------
    # Set default values
    #------------------------------------------------
    if(!$FuzzNum)
    {
        [int]$FuzzNum = 300
    }

    # -----------------------------------------------
    # Connect to the sql server
    # -----------------------------------------------
    # Create fun connection object
    $conn = New-Object  -TypeName System.Data.SqlClient.SqlConnection

    # Check for domain credentials
    if($SqlUser)
    {
        $DomainUserCheck = $SqlUser.Contains('\')
    }

    # Set authentication type and create connection string
    if($SqlUser -and $SqlPassword -and !$DomainUserCheck)
    {
        # SQL login / alternative domain credentials
        $conn.ConnectionString = "Server=$SqlServerInstance;Database=master;User ID=$SqlUser;Password=$SqlPass;"
        [string]$ConnectUser = $SqlUser
    }
    else
    {
        # Create credentials management entry if a domain user is used
        if ($DomainUserCheck -and (Test-Path  ('C:\Windows\System32\cmdkey.exe')))
        {
            Write-Output  -InputObject "[*] Attempting to authenticate to $SqlServerInstance with domain account $SqlUser..."
            $SqlServerInstanceCol = $SqlServerInstance -replace ',', ':'
            $CredManCmd = 'cmdkey /add:'+$SqlServerInstanceCol+' /user:'+$SqlUser+' /pass:'+$SqlPass 
            Write-Verbose  -Message "Command: $CredManCmd"
            $ExecManCmd = Invoke-Expression  -Command $CredManCmd
        }
        else
        {
            Write-Output  -InputObject "[*] Attempting to authenticate to $SqlServerInstance as the current Windows user..."
        }

        # Trusted connection
        $conn.ConnectionString = "Server=$SqlServerInstance;Database=master;Integrated Security=SSPI;"   
        $UserDomain = [Environment]::UserDomainName
        $Username = [Environment]::UserName
        $ConnectUser = "$UserDomain\$Username"
    }

    # Attempt database connection
    try
    {
        $conn.Open()
        $conn.Close()
        Write-Host  -Object '[*] Connected.' -ForegroundColor 'green'
    }
    catch
    {
        $ErrorMessage = $_.Exception.Message
        Write-Host  -Object '[*] Connection failed' -ForegroundColor 'red'
        Write-Host  -Object "[*] Error: $ErrorMessage" -ForegroundColor 'red'

        # Clean up credentials manager entry
        if ($DomainUserCheck)
        {
            $CredManDel = 'cmdkey /delete:'+$SqlServerInstanceCol
            Write-Verbose  -Message "Command: $CredManDel"   
            $ExecManDel = Invoke-Expression  -Command $CredManDel
        }
        Break
    }


    # -----------------------------------------------
    # Enumerate sql server logins with SUSER_NAME()
    # -----------------------------------------------
    Write-Host  -Object "[*] Setting up to fuzz $FuzzNum SQL Server logins." 
    Write-Host  -Object '[*] Enumerating logins...'

    # Open database connection
    $conn.Open()

    # Create table to store results
    $MyQueryResults = New-Object  -TypeName System.Data.DataTable
    $MyQueryResultsClean = New-Object  -TypeName System.Data.DataTable
    $null = $MyQueryResultsClean.Columns.Add('name') 

    # Creat loop to fuzz principal_id number
    $PrincipalID = 0

    do 
    {
        # incrememt number
        $PrincipalID++

        # Setup query
        $query = "SELECT SUSER_NAME($PrincipalID) as name"

        # Execute query
        $cmd = New-Object  -TypeName System.Data.SqlClient.SqlCommand -ArgumentList ($query, $conn)

        # Parse results
        $results = $cmd.ExecuteReader()
        $MyQueryResults.Load($results)
    }
    while ($PrincipalID -le $FuzzNum-1)    

    # Filter list of sql logins
    $MyQueryResults |
    Select-Object name -Unique |
    Where-Object  -FilterScript {
        $_.name -notlike '*##*'
    } |
    Where-Object  -FilterScript {
        $_.name -notlike ''
    } |
    ForEach-Object  -Process {
        # Get sql login name
        $SqlLoginName = $_.name

        # add cleaned up list to new data table
        $null = $MyQueryResultsClean.Rows.Add($SqlLoginName)
    }

    # Close database connection
    $conn.Close()

    # Display initial login count
    $SqlLoginCount = $MyQueryResultsClean.Rows.Count
    Write-Verbose  -Message "[*] $SqlLoginCount initial logins were found." 


    # ----------------------------------------------------
    # Validate sql login with sp_defaultdb error ananlysis
    # ----------------------------------------------------

    # Status user
    Write-Host  -Object '[*] Verifying the logins...'

    # Open database connection
    $conn.Open()

    # Create table to store results
    $SqlLoginVerified = New-Object  -TypeName System.Data.DataTable
    $null = $SqlLoginVerified.Columns.Add('name') 

    # Check if sql logins are valid 
    #$MyQueryResultsClean | Sort-Object name
    $MyQueryResultsClean |
    Sort-Object  -Property name |
    ForEach-Object  -Process {
        # Get sql login name
        $SqlLoginNameTest = $_.name
    
        # Setup query
        $query = "EXEC sp_defaultdb '$SqlLoginNameTest', 'NOTAREALDATABASE1234ABCD'"

        # Execute query
        $cmd = New-Object  -TypeName System.Data.SqlClient.SqlCommand -ArgumentList ($query, $conn)

        try
        {
            $results = $cmd.ExecuteReader()
        }
        catch
        {
            $ErrorMessage = $_.Exception.Message  

            # Check the error message for a signature that means the login is real
            if (($ErrorMessage -like '*NOTAREALDATABASE*') -or ($ErrorMessage -like '*alter the login*'))
            {
                $null = $SqlLoginVerified.Rows.Add($SqlLoginNameTest)
            }                  
        }
    }

    # Close database connection
    $conn.Close()

    # Display verified logins
    $SqlLoginVerifiedCount = $SqlLoginVerified.Rows.Count
    if ($SqlLoginVerifiedCount -ge 1)
    {
        Write-Host  -Object "[*] $SqlLoginVerifiedCount logins verified:" -ForegroundColor 'green'
        $SqlLoginVerified |
        Select-Object name -Unique|
        Sort-Object  -Property name 
    }
    else
    {
        Write-Host  -Object '[*] No verified logins found.' -ForegroundColor 'red'
    }

    # Clean up credentials manager entry
    if ($DomainUserCheck)
    {
        $CredManDel = 'cmdkey /delete:'+$SqlServerInstanceCol
        Write-Verbose  -Message "Command: $CredManDel"   
        $ExecManDel = Invoke-Expression  -Command $CredManDel
    }
}
