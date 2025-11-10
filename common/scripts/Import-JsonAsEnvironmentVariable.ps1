function Import-JsonAsEnvironmentVariable {
    <#
    .SYNOPSIS
        Imports JSON/JSONC file content as environment variables

    .DESCRIPTION
        Reads a JSON or JSONC (JSON with Comments) file and sets each key/value pair as environment
        variables. Nested objects are flattened using dot notation and converted to POSIX convention
        (uppercase with underscores). For example, "Database.Server" becomes "DATABASE_SERVER".

        Supports JSONC features:
        - Single-line comments (//)
        - Multi-line comments (/* */)
        - Trailing commas

        The function automatically detects if it's running in an Azure DevOps environment by
        checking for the System.CollectionUri environment variable:

        - If System.CollectionUri exists: Sets variables as Azure DevOps pipeline variables using
          the ##vso[task.setvariable] logging command. Variables are available to downstream tasks.

        - If System.CollectionUri is not set: Sets variables as standard PowerShell environment
          variables using Set-Item. Variables are available in the current PowerShell session.

    .PARAMETER Path
        The path to the JSON or JSONC file to import. Must be a valid file path.
        Supports both .json and .jsonc file extensions.

    .PARAMETER Prefix
        Optional prefix to add to all variable names. Useful for namespacing variables.

    .EXAMPLE
        Import-JsonAsEnvironmentVariable -Path './config.json'
        # Imports all key/value pairs from config.json as environment variables
        # Sets as Azure DevOps variables if running in a pipeline, otherwise as PowerShell env vars

    .EXAMPLE
        Import-JsonAsEnvironmentVariable -Path './settings.jsonc'
        # Imports from a JSONC file with comments
        # Comments are automatically stripped before parsing

    .EXAMPLE
        Import-JsonAsEnvironmentVariable -Path './settings.json' -Prefix 'APP_'
        # Imports all key/value pairs with APP_ prefix (e.g., APP_Version, APP_Environment)
        # Automatically detects environment and sets variables accordingly

    .EXAMPLE
        # Sample JSON file content:
        # {
        #   "Version": "1.0.0",
        #   "Environment": "Production",
        #   "Database": {
        #     "Server": "sql.example.com",
        #     "Port": 1433
        #   }
        # }
        #
        # Results in POSIX convention environment variables:
        # - VERSION = "1.0.0"
        # - ENVIRONMENT = "Production"
        # - DATABASE_SERVER = "sql.example.com"
        # - DATABASE_PORT = 1433

    .OUTPUTS
        PSCustomObject with import results including variable count and names

    .NOTES
        Author: The Cloud Explorers
        Requires PowerShell 7.0 or later
        Automatically detects Azure DevOps environment via System.CollectionUri
        Version: 1.1.0
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$Prefix = ''
    )

    begin {
        Write-Verbose "Starting JSON environment variable import"

        # Detect if running in Azure DevOps environment
        $IsAzureDevOps = -not [string]::IsNullOrEmpty($env:SYSTEM_COLLECTIONURI)

        if ($IsAzureDevOps) {
            Write-Verbose "Detected Azure DevOps environment (System.CollectionUri: $env:SYSTEM_COLLECTIONURI)"
            Write-Verbose "Variables will be set as Azure DevOps pipeline variables"
        }
        else {
            Write-Verbose "Not running in Azure DevOps environment"
            Write-Verbose "Variables will be set as PowerShell environment variables"
        }
    }

    process {
        try {
            # Validate file exists
            if (-not (Test-Path -Path $Path -PathType Leaf)) {
                throw "File not found: $Path"
            }

            Write-Verbose "Reading JSON/JSONC file: $Path"

            # Read and parse JSON file (supports JSONC with comments)
            $JsonContent = Get-Content -Path $Path -Raw -ErrorAction Stop

            # Remove JSONC comments (single-line // and multi-line /* */)
            # Remove single-line comments
            $JsonContent = $JsonContent -replace '(?m)^\s*//.*$', ''
            # Remove multi-line comments
            $JsonContent = $JsonContent -replace '(?s)/\*.*?\*/', ''
            # Remove trailing commas before closing braces/brackets
            $JsonContent = $JsonContent -replace ',(\s*[}\]])', '$1'

            $JsonObject = $JsonContent | ConvertFrom-Json -ErrorAction Stop

            if ($null -eq $JsonObject) {
                throw "JSON/JSONC file is empty or invalid: $Path"
            }

            Write-Verbose "Successfully parsed JSON/JSONC file"

            # Flatten JSON object and set environment variables
            $VariableCount = 0
            $VariableNames = @()

            $FlattenedVariables = ConvertTo-FlatHashtable -InputObject $JsonObject -Prefix $Prefix

            foreach ($Key in $FlattenedVariables.Keys) {
                $Value = $FlattenedVariables[$Key]

                # Convert key to POSIX convention (uppercase with underscores)
                $PosixKey = ConvertTo-PosixVariableName -Name $Key

                # Convert value to string
                $StringValue = if ($null -eq $Value) {
                    ''
                }
                elseif ($Value -is [bool]) {
                    $Value.ToString().ToLower()
                }
                else {
                    $Value.ToString()
                }

                # Set variable based on environment
                if ($IsAzureDevOps) {
                    # Set Azure DevOps pipeline variable
                    Write-Host "##vso[task.setvariable variable=$PosixKey]$StringValue"
                    Write-Verbose "Set Azure DevOps pipeline variable: $PosixKey = $StringValue"
                }
                else {
                    # Set PowerShell environment variable
                    Set-Item -Path "env:$PosixKey" -Value $StringValue -ErrorAction Stop
                    Write-Verbose "Set PowerShell environment variable: $PosixKey = $StringValue"
                }

                $VariableCount++
                $VariableNames += $PosixKey
            }

            # Create result object
            $Result = [PSCustomObject]@{
                Status        = 'Success'
                FilePath      = $Path
                VariableCount = $VariableCount
                VariableNames = $VariableNames
                Prefix        = $Prefix
                ImportedAt    = Get-Date
            }

            Write-Host "Successfully imported $VariableCount variable(s) from JSON file" -ForegroundColor Green

            return $Result
        }
        catch {
            $ErrorMessage = "Failed to import JSON as environment variables: $($_.Exception.Message)"
            Write-Error $ErrorMessage
            throw $_
        }
    }

    end {
        Write-Verbose "JSON environment variable import completed"
    }
}

function ConvertTo-FlatHashtable {
    <#
    .SYNOPSIS
        Flattens a nested object into a hashtable with dot notation keys

    .DESCRIPTION
        Recursively flattens a PSCustomObject or hashtable into a flat hashtable where
        nested properties are represented using dot notation (e.g., parent.child).

    .PARAMETER InputObject
        The object to flatten (PSCustomObject, Hashtable, or primitive value)

    .PARAMETER Prefix
        The current key prefix for nested properties

    .OUTPUTS
        Hashtable with flattened key/value pairs
    #>

    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $false)]
        [string]$Prefix = ''
    )

    $Result = @{}

    if ($null -eq $InputObject) {
        return $Result
    }

    # Handle different input types
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        # Convert PSCustomObject to hashtable
        $Properties = $InputObject.PSObject.Properties

        foreach ($Property in $Properties) {
            $Key = if ($Prefix) { "$Prefix.$($Property.Name)" } else { $Property.Name }
            $Value = $Property.Value

            if ($null -eq $Value) {
                $Result[$Key] = $null
            }
            elseif ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [hashtable]) {
                # Recursively flatten nested objects
                $Nested = ConvertTo-FlatHashtable -InputObject $Value -Prefix $Key
                foreach ($NestedKey in $Nested.Keys) {
                    $Result[$NestedKey] = $Nested[$NestedKey]
                }
            }
            elseif ($Value -is [array]) {
                # Arrays are converted to JSON string representation
                $Result[$Key] = ($Value | ConvertTo-Json -Compress -Depth 10)
            }
            else {
                # Primitive value
                $Result[$Key] = $Value
            }
        }
    }
    elseif ($InputObject -is [hashtable]) {
        # Handle hashtable input
        foreach ($Key in $InputObject.Keys) {
            $FullKey = if ($Prefix) { "$Prefix.$Key" } else { $Key }
            $Value = $InputObject[$Key]

            if ($null -eq $Value) {
                $Result[$FullKey] = $null
            }
            elseif ($Value -is [System.Management.Automation.PSCustomObject] -or $Value -is [hashtable]) {
                # Recursively flatten nested objects
                $Nested = ConvertTo-FlatHashtable -InputObject $Value -Prefix $FullKey
                foreach ($NestedKey in $Nested.Keys) {
                    $Result[$NestedKey] = $Nested[$NestedKey]
                }
            }
            elseif ($Value -is [array]) {
                # Arrays are converted to JSON string representation
                $Result[$FullKey] = ($Value | ConvertTo-Json -Compress -Depth 10)
            }
            else {
                # Primitive value
                $Result[$FullKey] = $Value
            }
        }
    }
    else {
        # Single primitive value
        $Result[$Prefix] = $InputObject
    }

    return $Result
}

function ConvertTo-PosixVariableName {
    <#
    .SYNOPSIS
        Converts a variable name to POSIX convention

    .DESCRIPTION
        Converts a variable name to POSIX convention by:
        - Converting to uppercase
        - Replacing dots (.) with underscores (_)
        - Replacing hyphens (-) with underscores (_)
        - Removing invalid characters

    .PARAMETER Name
        The variable name to convert

    .OUTPUTS
        String in POSIX convention (uppercase with underscores)

    .EXAMPLE
        ConvertTo-PosixVariableName -Name 'Database.Server'
        # Returns: DATABASE_SERVER

    .EXAMPLE
        ConvertTo-PosixVariableName -Name 'my-app.version'
        # Returns: MY_APP_VERSION
    #>

    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    # Convert to uppercase
    $Result = $Name.ToUpper()

    # Replace dots and hyphens with underscores
    $Result = $Result -replace '[.\-]', '_'

    # Remove any characters that are not alphanumeric or underscore
    $Result = $Result -replace '[^A-Z0-9_]', ''

    # Ensure it doesn't start with a number (prepend underscore if it does)
    if ($Result -match '^\d') {
        $Result = "_$Result"
    }

    return $Result
}
