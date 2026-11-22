$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\update-scrum-classes.ps1'
$global:scrumInvocationTestWrites = [System.Collections.Generic.List[object]]::new()
$global:scrumInvocationTestSearches = [System.Collections.Generic.List[object]]::new()
$date = [DateTime]::UtcNow.Date.AddDays(10).ToString('yyyy-MM-dd')
$pageContent = '{"root":{"children":[{"type":"html","html":"before<!-- SCRUM-CLASS-LIST:START -->old<!-- SCRUM-CLASS-LIST:END -->after"}],"type":"root"}}'
$postContent = '{"root":{"children":[{"type":"markdown","markdown":"before<!--SCRUM TRAINING:318-->old<!--/SCRUM TRAINING-->after"}],"type":"root"}}'

function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $Body, $ErrorAction, $ContentType)
    if ($Uri -eq 'https://www.scrum.org/api/class-search') {
        $global:scrumInvocationTestSearches.Add(($Body | ConvertFrom-Json))
        return [pscustomobject]@{
            totalItems = 1
            items = @(@{
                StartDate = $date; EndDate = $date; Title = 'Sample class'
                url = '/courses/sample'; languages = @('English'); location = 'Online'
            })
        }
    }
    if ($Method -eq 'PUT') {
        $global:scrumInvocationTestWrites.Add(@{ uri = $Uri; payload = ($Body | ConvertFrom-Json -AsHashtable) })
        return @{}
    }
    switch -Regex ($Uri) {
        '/pages/\?limit=' { return @{ pages = @(@{ id = 'page1' }); meta = @{ pagination = @{ next = $null } } } }
        '/posts/\?limit=' { return @{ posts = @(@{ id = 'post1' }); meta = @{ pagination = @{ next = $null } } } }
        '/pages/page1/\?' { return @{ pages = @(@{ updated_at = 'page-revision'; lexical = $pageContent }) } }
        '/posts/post1/\?' { return @{ posts = @(@{ updated_at = 'post-revision'; lexical = $postContent; tags = @(@{ slug = 'hash-training' }) }) } }
        default { throw "Unexpected request: $Method $Uri" }
    }
}

& $scriptPath -trainerId '76' -token 'test:00112233445566778899aabbccddeeff' -userAgent 'test'
if ($global:scrumInvocationTestWrites.Count -ne 2) {
    throw "Expected page and post updates, got $($global:scrumInvocationTestWrites.Count)."
}
if ($global:scrumInvocationTestSearches.Count -ne 2 -or
    $global:scrumInvocationTestSearches[0].trainerId -ne '76' -or
    $global:scrumInvocationTestSearches[1].trainerId -ne '76' -or
    $global:scrumInvocationTestSearches[1].courseTypes[0] -ne '318') {
    throw 'The invoked script did not pass the expected trainer and course filters.'
}
foreach ($write in $global:scrumInvocationTestWrites) {
    $type = if ($write.uri -match '/pages/') { 'pages' } else { 'posts' }
    $entry = $write.payload[$type][0]
    if ($entry.Keys.Count -ne 2 -or -not $entry.ContainsKey('lexical') -or -not $entry.ContainsKey('updated_at')) {
        throw "Unexpected $type update fields."
    }
    $content = $entry.lexical | ConvertFrom-Json -AsHashtable
    $node = $content.root.children[0]
    $text = if ($type -eq 'pages') { $node.html } else { $node.markdown }
    if (-not $text.Contains('Sample class') -or -not $text.StartsWith('before') -or -not $text.EndsWith('after')) {
        throw "Schedule or surrounding content missing for $type."
    }
}
Remove-Variable -Name scrumInvocationTestWrites -Scope Global
Remove-Variable -Name scrumInvocationTestSearches -Scope Global
Write-Output 'Script invocation test passed.'
