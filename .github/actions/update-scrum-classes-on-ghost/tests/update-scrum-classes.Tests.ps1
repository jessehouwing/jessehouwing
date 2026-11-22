$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\update-scrum-classes.ps1'
. $scriptPath -trainerId '76' -token 'unused' -userAgent 'test'

function Assert-Equal {
    param([string]$expected, [string]$actual, [string]$testName)
    if ($expected -cne $actual) {
        throw "$testName failed. Expected '$expected', got '$actual'."
    }
}

function Assert-True {
    param([bool]$value, [string]$testName)
    if (-not $value) {
        throw "$testName failed."
    }
}

$future = [DateTime]::UtcNow.Date.AddDays(10).ToString('yyyy-MM-dd')
$past = [DateTime]::UtcNow.Date.AddDays(-2).ToString('yyyy-MM-dd')
$futureClass = @{
    StartDate = $future; EndDate = $future; Title = 'Scrum & <Agile>'
    url = '/courses/example?x=1&y=2'; languages = @('English'); location = 'A & B'
}
$pastClass = @{
    StartDate = $past; EndDate = $past; Title = 'Expired class'
    url = '/courses/past'; languages = @('English'); location = 'Online'
}
$secondPageClass = @{
    StartDate = $future; EndDate = $future; Title = 'Second page class'
    url = '/courses/second'; languages = @('Dutch'); location = 'Online'
}
$script:searches = [System.Collections.Generic.List[object]]::new()

function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $Body, $ErrorAction, $ContentType)
    if ($Uri -eq 'https://scrumbug.ghost.io/ghost/api/admin/pages/') {
        Assert-True ($Headers.Authorization.StartsWith('Ghost ')) 'Ghost request authenticates'
        return [pscustomobject]@{ pages = @(); meta = @{ pagination = @{ next = $null } } }
    }
    if ($Uri -ne 'https://www.scrum.org/api/class-search' -or $Method -ne 'POST') {
        throw "Unexpected external request: $Method $Uri"
    }
    Assert-Equal 'application/json' $ContentType 'Scrum request content type'
    $query = $Body | ConvertFrom-Json
    $script:searches.Add($query)
    if ($query.trainerId -eq 'invalid-response') {
        return [pscustomobject]@{ error = 'unavailable' }
    }
    if ($query.courseTypes -contains '99') {
        return [pscustomobject]@{ items = @($pastClass); totalItems = 1 }
    }
    if ($query.courseTypes -contains '100') {
        return [pscustomobject]@{ items = @(); totalItems = 0 }
    }
    if ($query.courseTypes -contains '101') {
        return [pscustomobject]@{ items = @($futureClass); totalItems = 21 }
    }
    if ($query.courseTypes -contains '12') {
        if ($query.page -eq 1) {
            return [pscustomobject]@{ items = (@($futureClass) + (@($pastClass) * 19)); totalItems = 21 }
        }
        return [pscustomobject]@{ items = @($secondPageClass); totalItems = 21 }
    }
    return [pscustomobject]@{ items = @($futureClass, $pastClass); totalItems = 2 }
}

$token = 'test:00112233445566778899aabbccddeeff'
$requestResult = Invoke-GhostRequest -uri 'https://scrumbug.ghost.io/ghost/api/admin/pages/' -method GET
Assert-True ($null -ne $requestResult.meta.pagination) 'Ghost response is not mixed with log output'

$start = '<!-- SCRUM-CLASS-LIST:START -->'
$end = '<!-- SCRUM-CLASS-LIST:END -->'
$allInput = "before$start<span>stale</span>$end after"
$html = Update-TrainingContent -content $allInput -trainerId '76' -format html
Assert-True ($html.StartsWith("before$start`n<table>")) 'HTML starts with a table inside markers'
Assert-True ($html.EndsWith("</tbody></table>`n$end after")) 'HTML keeps surrounding content'
Assert-True ($html.Contains('Scrum &amp; &lt;Agile&gt;')) 'HTML escapes class title'
Assert-True ($html.Contains('href="https://scrum.org/courses/example?x=1&amp;y=2"')) 'HTML escapes link'
Assert-True ($html.Contains('A &amp; B')) 'HTML escapes location'
Assert-True (-not $html.Contains('Expired class')) 'HTML excludes expired classes'

$courseInput = '<!--SCRUM TRAINING:12-->old<!--/SCRUM TRAINING-->|<!--SCRUM TRAINING:99-->expired<!--/SCRUM TRAINING-->'
$markdown = Update-TrainingContent -content $courseInput -trainerId '76' -format markdown
Assert-True ($markdown.Contains('| [Scrum & <Agile>](https://scrum.org/courses/example?x=1&y=2) |')) 'Markdown renders course'
Assert-True ($markdown.Contains('[Second page class]')) 'Scrum search includes later pages'
Assert-True ($markdown.Contains("<!--SCRUM TRAINING:99-->`n<!--/SCRUM TRAINING-->")) 'No classes clears stale schedule'
Assert-Equal '12' $script:searches[1].courseTypes[0] 'First course filter'
Assert-Equal '2' $script:searches[2].page 'Second Scrum search page'
Assert-Equal '99' $script:searches[3].courseTypes[0] 'Second course filter'
Assert-Equal '76' $script:searches[3].trainerId 'Trainer filter'
$emptyHtml = Update-TrainingContent -content '<!--SCRUM TRAINING:100-->old<!--/SCRUM TRAINING-->' -trainerId '76' -format html
Assert-Equal "<!--SCRUM TRAINING:100-->`n<!--/SCRUM TRAINING-->" $emptyHtml 'Empty search clears old HTML schedule'
$failed = $false
try {
    $null = Update-TrainingContent -content '<!--SCRUM TRAINING:101-->old<!--/SCRUM TRAINING-->' -trainerId '76' -format html
}
catch {
    $failed = $true
}
Assert-True $failed 'Incomplete search page fails instead of saving a partial schedule'

$legacy = Update-TrainingContent -content '<!--SCRUM TRAINING-->old<!--/SCRUM TRAINING-->' -trainerId '76' -format markdown
Assert-True ($legacy.Contains('| Course | Dates |')) 'Legacy all-classes marker'
$unchanged = 'Unrelated content with $1 and <b>HTML</b>'
Assert-Equal $unchanged (Update-TrainingContent -content $unchanged -trainerId '76' -format html) 'No markers unchanged'
$failed = $false
try {
    $null = Update-TrainingContent -content $allInput -trainerId 'invalid-response' -format html
}
catch {
    $failed = $true
}
Assert-True $failed 'Invalid search response fails instead of clearing a schedule'

$mobiledoc = @'
{"version":"0.3.1","cards":[["html",{"html":"before<!-- SCRUM-CLASS-LIST:START --><p>old</p><!-- SCRUM-CLASS-LIST:END -->after","other":"keep"}],["markdown",{"markdown":"<!--SCRUM TRAINING:99-->old<!--/SCRUM TRAINING-->"}],["image",{"src":"untouched"}]],"sections":[]}
'@ | ConvertFrom-Json -AsHashtable
$mobileResult = Update-Mobiledoc -mobiledoc $mobiledoc -trainerId '76'
Assert-True ($mobileResult.cards[0][1].html.Contains('<table>')) 'Mobiledoc HTML card'
Assert-Equal 'keep' $mobileResult.cards[0][1].other 'Mobiledoc HTML metadata'
Assert-Equal "<!--SCRUM TRAINING:99-->`n<!--/SCRUM TRAINING-->" $mobileResult.cards[1][1].markdown 'Mobiledoc Markdown card'
Assert-Equal 'untouched' $mobileResult.cards[2][1].src 'Mobiledoc unrelated card'

$lexicalJson = @'
{"root":{"children":[{"type":"html","version":1,"html":"before<!-- SCRUM-CLASS-LIST:START -->old<!-- SCRUM-CLASS-LIST:END -->after"},{"type":"markdown","version":1,"markdown":"<!--SCRUM TRAINING:12-->old<!--/SCRUM TRAINING-->"},{"type":"paragraph","children":[{"type":"extended-text","text":"untouched"}]}],"type":"root","version":1}}
'@
$lexical = $lexicalJson | ConvertFrom-Json -AsHashtable
$lexicalResult = Update-Lexical -lexical $lexical -trainerId '76'
Assert-True ($lexicalResult.root.children[0].html.Contains('<table>')) 'Lexical HTML card'
Assert-True ($lexicalResult.root.children[1].markdown.Contains('| Course |')) 'Lexical Markdown card'
Assert-Equal 'untouched' $lexicalResult.root.children[2].children[0].text 'Lexical unrelated content'

$script:calls = [System.Collections.Generic.List[object]]::new()
$script:writes = [System.Collections.Generic.List[object]]::new()
$pageMobile = @'
{"version":"0.3.1","cards":[["html",{"html":"prefix<!-- SCRUM-CLASS-LIST:START -->old<!-- SCRUM-CLASS-LIST:END -->suffix"}],["image",{"src":"keep"}]],"sections":[]}
'@
$postLexical = @'
{"root":{"children":[{"type":"markdown","version":1,"markdown":"prefix<!--SCRUM TRAINING:99-->expired<!--/SCRUM TRAINING-->suffix"},{"type":"paragraph","children":[{"type":"extended-text","text":"keep"}]}],"type":"root","version":1}}
'@
$untouchedLexical = '{"root":{"children":[{"type":"html","html":"untouched"}],"type":"root"}}'

function Invoke-GhostRequest {
    param([string]$uri, [string]$method, [string]$body)
    $script:calls.Add("$method $uri")
    if ($method -eq 'PUT') {
        $script:writes.Add(@{ uri = $uri; payload = ($body | ConvertFrom-Json -AsHashtable) })
        return @{}
    }
    switch -Regex ($uri) {
        '/pages/\?limit=100&page=1&' { return @{ pages = @(@{ id = 'page1' }); meta = @{ pagination = @{ next = 2 } } } }
        '/pages/\?limit=100&page=2&' { return @{ pages = @(@{ id = 'page2' }); meta = @{ pagination = @{ next = $null } } } }
        '/posts/\?limit=100&page=1&.*&filter=tag%3Ahash-training$' { return @{ posts = @(@{ id = 'post1' }); meta = @{ pagination = @{ next = 2 } } } }
        '/posts/\?limit=100&page=2&.*&filter=tag%3Ahash-training$' { return @{ posts = @(@{ id = 'post2' }, @{ id = 'post3' }); meta = @{ pagination = @{ next = $null } } } }
        '/pages/page1/\?formats=lexical,mobiledoc&include=tags$' { return @{ pages = @(@{ updated_at = 'page-revision'; mobiledoc = $pageMobile }) } }
        '/pages/page2/\?formats=lexical,mobiledoc&include=tags$' { return @{ pages = @(@{ updated_at = 'unchanged'; lexical = $untouchedLexical }) } }
        '/posts/post1/\?formats=lexical,mobiledoc&include=tags$' { return @{ posts = @(@{ updated_at = 'post-revision'; lexical = $postLexical; tags = @(@{ slug = 'hash-training' }) }) } }
        '/posts/post2/\?formats=lexical,mobiledoc&include=tags$' { return @{ posts = @(@{ updated_at = 'unchanged'; lexical = $untouchedLexical; tags = @(@{ slug = 'hash-training' }) }) } }
        '/posts/post3/\?formats=lexical,mobiledoc&include=tags$' { return @{ posts = @(@{ updated_at = 'retagged'; lexical = $postLexical; tags = @(@{ slug = 'other' }) }) } }
        default { throw "Unexpected Ghost request: $method $uri" }
    }
}

Update-GhostSchedules -trainerId '76'
Assert-Equal '2' $script:writes.Count 'Only changed page and post written'
Assert-True ($script:calls.IndexOf(($script:calls | Where-Object { $_ -match '/pages/\?limit=100&page=2&' } | Select-Object -First 1)) -lt $script:calls.IndexOf(($script:calls | Where-Object { $_ -match '^PUT .*/pages/page1/$' } | Select-Object -First 1))) 'Pages discovered before changes'
Assert-True ($script:calls.IndexOf(($script:calls | Where-Object { $_ -match '/posts/\?limit=100&page=2&' } | Select-Object -First 1)) -lt $script:calls.IndexOf(($script:calls | Where-Object { $_ -match '^PUT .*/posts/post1/$' } | Select-Object -First 1))) 'Posts discovered before changes'
$pageWrite = $script:writes | Where-Object { $_.uri -match '/pages/page1/$' }
$postWrite = $script:writes | Where-Object { $_.uri -match '/posts/post1/$' }
Assert-Equal 'page-revision' $pageWrite.payload.pages[0].updated_at 'Page revision preserved'
Assert-Equal 'post-revision' $postWrite.payload.posts[0].updated_at 'Post revision preserved'
$pageContent = $pageWrite.payload.pages[0].mobiledoc | ConvertFrom-Json -AsHashtable
$postContent = $postWrite.payload.posts[0].lexical | ConvertFrom-Json -AsHashtable
Assert-True ($pageContent.cards[0][1].html.Contains('<table>')) 'Page PUT has HTML'
Assert-Equal 'keep' $pageContent.cards[1][1].src 'Page PUT preserves other card'
Assert-Equal "prefix<!--SCRUM TRAINING:99-->`n<!--/SCRUM TRAINING-->suffix" $postContent.root.children[0].markdown 'Post PUT clears stale schedule'
Assert-Equal 'keep' $postContent.root.children[1].children[0].text 'Post PUT preserves unrelated content'

Write-Output 'All Scrum schedule updater tests passed.'
