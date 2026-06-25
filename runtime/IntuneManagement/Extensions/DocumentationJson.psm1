function Get-ModuleVersion
{
    '1.0.0'
}

function Invoke-InitializeModule
{
    Add-OutputType ([PSCustomObject]@{
        Name           = "Json"
        Value          = "json"
        OutputOptions  = (Add-JsonOptionsControl)
        PreProcess     = { Invoke-JsonPreProcessItems @args }
        NewObjectGroup = { Invoke-JsonNewObjectGroup @args }
        NewObjectType  = { Invoke-JsonNewObjectType @args }
        Process        = { Invoke-JsonProcessItem @args }
        PostProcess    = { Invoke-JsonPostProcessItems @args }
    })
}

function Add-JsonOptionsControl
{
    $script:jsonForm = Get-XamlObject ($global:AppRootFolder + "\Xaml\DocumentationJsonOptions.xaml") -AddVariables

    Set-XamlProperty $script:jsonForm "txtJsonFileName" "Text" (Get-Setting "Documentation" "JsonDocumentName" "")
    Set-XamlProperty $script:jsonForm "chkJsonOpenDocument" "IsChecked" (Get-Setting "Documentation" "JsonOpenFile" $true)
    $outputFileTypes = '[ { "Name": "Single file", "Value": "Full" }, { "Name": "One file per object type", "Value": "ObjectType" } ]' | ConvertFrom-Json
    Set-XamlProperty $script:jsonForm "cbJsonOutputFile" "ItemsSource" $outputFileTypes
    Set-XamlProperty $script:jsonForm "cbJsonOutputFile" "SelectedValue" (Get-Setting "Documentation" "JsonOutputFileType" "Full")

    Add-XamlEvent $script:jsonForm "browseJsonFileName" "add_click" {
        $sf = [System.Windows.Forms.SaveFileDialog]::new()
        $sf.DefaultExt = "json"
        $sf.Filter = "Json (*.json)|*.json|All files (*.*)|*.*"
        if ($sf.ShowDialog() -eq "OK")
        {
            Set-XamlProperty $script:jsonForm "txtJsonFileName" "Text" $sf.FileName
            Save-Setting "Documentation" "JsonDocumentName" $sf.FileName
        }
    }

    $script:jsonForm
}

function Invoke-JsonPreProcessItems
{
    $script:jsonAllObjects         = [System.Collections.Generic.List[object]]::new()
    $script:jsonCurrentTypeObjects = [System.Collections.Generic.List[object]]::new()
    $script:jsonCurrentTypeName    = $null

    $script:jsonOutputType = Get-XamlProperty $script:jsonForm "cbJsonOutputFile" "SelectedValue" "Full"

    $jsonFileName = Get-XamlProperty $script:jsonForm "txtJsonFileName" "Text" ""

    Save-Setting "Documentation" "JsonDocumentName"   $jsonFileName
    Save-Setting "Documentation" "JsonOpenFile"       (Get-XamlProperty $script:jsonForm "chkJsonOpenDocument" "IsChecked")
    Save-Setting "Documentation" "JsonOutputFileType" $script:jsonOutputType

    $script:jsonOutFile      = Expand-FileName (?? $jsonFileName "%MyDocuments%\%Organization%-%Date%.json")
    $script:jsonDocumentPath = [IO.Path]::GetDirectoryName($script:jsonOutFile)
}

function Invoke-JsonNewObjectGroup
{
    param($groupId)
    # Groups are not used in flat Json output
}

function Invoke-JsonNewObjectType
{
    param($objectTypeName)

    if ($script:jsonOutputType -eq "ObjectType" -and
        $script:jsonCurrentTypeName -and
        $script:jsonCurrentTypeObjects.Count -gt 0)
    {
        Save-JsonTypeFile $script:jsonCurrentTypeName $script:jsonCurrentTypeObjects
    }

    $script:jsonCurrentTypeName    = $objectTypeName
    $script:jsonCurrentTypeObjects = [System.Collections.Generic.List[object]]::new()
}

function Invoke-JsonProcessItem
{
    param($obj, $objectType, $documentedObj)

    if (-not $documentedObj -or -not $obj -or -not $objectType) { return }

    $objName = Get-GraphObjectName $obj $objectType

    try
    {
        $jsonObj = [ordered]@{
            objectType = $objectType.Title
            name       = $objName
        }

        # BasicInfo as a flat key/value object
        if ($documentedObj.BasicInfo.Count -gt 0)
        {
            $basicInfo = [ordered]@{}
            foreach ($item in $documentedObj.BasicInfo)
            {
                if ($item.Name) { $basicInfo[$item.Name] = $item.Value }
            }
            $jsonObj.basicInfo = $basicInfo
        }

        # Detailed settings as an array
        if ($documentedObj.FilteredSettings.Count -gt 0)
        {
            $settings = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $documentedObj.FilteredSettings)
            {
                $setting = [ordered]@{ name = $item.Name; value = $item.Value }
                if ($item.Category)    { $setting.category    = $item.Category }
                if ($item.SubCategory) { $setting.subCategory = $item.SubCategory }
                $settings.Add($setting)
            }
            $jsonObj.settings = $settings
        }

        # Compliance actions
        if (($documentedObj.ComplianceActions | Measure-Object).Count -gt 0)
        {
            $actions = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $documentedObj.ComplianceActions)
            {
                $actions.Add([ordered]@{
                    action          = $item.Action
                    schedule        = $item.Schedule
                    messageTemplate = $item.MessageTemplate
                    emailCC         = $item.EmailCC
                })
            }
            $jsonObj.complianceActions = $actions
        }

        # Applicability rules
        if (($documentedObj.ApplicabilityRules | Measure-Object).Count -gt 0)
        {
            $rules = [System.Collections.Generic.List[object]]::new()
            foreach ($item in $documentedObj.ApplicabilityRules)
            {
                $rules.Add([ordered]@{
                    rule     = $item.Rule
                    property = $item.Property
                    value    = $item.Value
                })
            }
            $jsonObj.applicabilityRules = $rules
        }

        # Custom tables — each becomes a top-level array keyed by the last segment of the language ID
        foreach ($customTable in ($documentedObj.CustomTables | Sort-Object -Property Order))
        {
            if (-not $customTable.Values -or ($customTable.Values | Measure-Object).Count -eq 0) { continue }

            $tableKey = if ($customTable.LanguageId) { $customTable.LanguageId.Split('.')[-1] } else { "customTable" }
            $tableArr = [System.Collections.Generic.List[object]]::new()

            foreach ($item in $customTable.Values)
            {
                $tableObj = [ordered]@{}
                foreach ($col in $customTable.Columns)
                {
                    $colName = $col.Split('.')[-1]
                    $tableObj[$colName] = "$($item.$colName)"
                }
                $tableArr.Add($tableObj)
            }
            $jsonObj[$tableKey] = $tableArr
        }

        # Assignments
        if (($documentedObj.Assignments | Measure-Object).Count -gt 0)
        {
            $assignments = [System.Collections.Generic.List[object]]::new()
            $hasRawIntent = $null -ne $documentedObj.Assignments[0].RawIntent

            foreach ($item in $documentedObj.Assignments)
            {
                if ($hasRawIntent)
                {
                    $assignObj = [ordered]@{
                        groupMode = $item.GroupMode
                        group     = $item.Group
                    }
                    if ($null -ne $item.Filter)     { $assignObj.filter     = $item.Filter }
                    if ($null -ne $item.FilterMode) { $assignObj.filterMode = $item.FilterMode }
                    if ($item.Settings)
                    {
                        $settingsObj = [ordered]@{}
                        foreach ($key in $item.Settings.Keys)
                        {
                            if ($key -in @("Category","RawIntent")) { continue }
                            $settingsObj[$key] = $item.Settings[$key]
                        }
                        $assignObj.settings = $settingsObj
                    }
                }
                else
                {
                    $assignObj = [ordered]@{ group = $item.Group }
                    if ($item.PSObject.Properties.Name -contains "Filter")     { $assignObj.filter     = $item.Filter }
                    if ($item.PSObject.Properties.Name -contains "FilterMode") { $assignObj.filterMode = $item.FilterMode }
                }
                $assignments.Add($assignObj)
            }
            $jsonObj.assignments = $assignments
        }

        # Scripts — included when "Document scripts" is checked in the documentation form
        if ($global:chkIncludeScripts.IsChecked -and ($documentedObj.Scripts | Measure-Object).Count -gt 0)
        {
            $scripts = [System.Collections.Generic.List[object]]::new()
            foreach ($scriptItem in $documentedObj.Scripts)
            {
                if (-not $scriptItem.ScriptContent) { continue }
                $scripts.Add([ordered]@{
                    caption = $scriptItem.Caption
                    content = $scriptItem.ScriptContent
                })
            }
            if ($scripts.Count -gt 0) { $jsonObj.scripts = $scripts }
        }

        $script:jsonCurrentTypeObjects.Add($jsonObj)
        if ($script:jsonOutputType -ne "ObjectType") { $script:jsonAllObjects.Add($jsonObj) }
    }
    catch
    {
        Write-LogError "Failed to process object $objName" $_.Exception
    }
}

function Invoke-JsonPostProcessItems
{
    $openFile = (Get-XamlProperty $script:jsonForm "chkJsonOpenDocument" "IsChecked") -eq $true

    if ($script:jsonOutputType -eq "ObjectType")
    {
        if ($script:jsonCurrentTypeName -and $script:jsonCurrentTypeObjects.Count -gt 0)
        {
            Save-JsonTypeFile $script:jsonCurrentTypeName $script:jsonCurrentTypeObjects
        }
        Write-Log "Json documentation saved to folder: $($script:jsonDocumentPath)"
    }
    else
    {
        $jsonContent = ConvertTo-Json -InputObject @($script:jsonAllObjects) -Depth 20
        Save-DocumentationFile $jsonContent $script:jsonOutFile -OpenFile:$openFile
    }
}

function Save-JsonTypeFile
{
    param($typeName, $objects)

    $safeTypeName = Remove-InvalidFileNameChars ($typeName.Replace(" ", "_"))
    $typeFileName = [IO.Path]::Combine($script:jsonDocumentPath, "$safeTypeName.json")
    $jsonContent  = ConvertTo-Json -InputObject @($objects) -Depth 20
    Save-DocumentationFile $jsonContent $typeFileName
    Write-Log "Saved $($objects.Count) objects to $typeFileName"
}
