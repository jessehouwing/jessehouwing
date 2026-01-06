param(
    [Parameter(Mandatory=$true)]
    [string]$trainerId,
    
    [Parameter(Mandatory=$true)]
    [string]$token,
    
    [Parameter(Mandatory=$true)]
    [string]$userAgent
)

$searchHeaders = @{
    "User-Agent" = $userAgent
}

Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
Install-Module -Name JWT -force

function get-markdown {
    param(
        [string]$trainerId,
        [string[]]$courses
    )

    if ($courses)
    {
      $body = @{ 
            trainerId   = "$trainerId"
            courseTypes = $courses
        }
    } else {
      $body = @{ trainerId   = "$trainerId" } 
    }
    
    $classes = Invoke-RestMethod -Uri "https://www.scrum.org/api/class-search" -Headers $searchHeaders -Method POST -Body ($body | ConvertTo-Json)

    if ($classes.items.Length -gt 0) {
        $markdown = "`n| Course | Dates | Language | Location |`n|--------|-------|----------|----------|`n"

        foreach ($course in $classes.items) {
            $startDate = get-date -date $course.StartDate
            $endDate = get-date -date $course.EndDate
            $dateString = ""

            if ($startDate -eq $endDate) {
                $dateString = "$($startDate.Day) $($startDate.ToString("MMM yyyy"))"
            }
            elseif ($startDate.Month -eq $endDate.Month) {
                $dateString = "$($startDate.Day)-$($endDate.Day) $($startDate.ToString("MMM yyyy"))"
            }
            elseif ($startDate.Month -ne $endDate.Month) {
                $dateString = "$($startDate.Day) $($startDate.ToString("MMM"))-$($endDate.Day) $($endDate.ToString("MMM yyyy"))"
            }

            $markdown += "| [$($course.Title)](https://scrum.org$($course.url)) | $dateString | $($course.languages[0]) | $($course.location) | "
            $markdown += "`n"
        }

        return $markdown
    }
}

function Update-Mobiledoc {
    param(
        [hashtable]$mobiledoc,
        [string]$trainerId
    )

    foreach ($card in $mobiledoc.cards) {
        if ($card[0] -eq "markdown") {
            $markdown = $card[1].markdown
            if ($markdown -match "<!--SCRUM TRAINING(:(?<course>\d+))?-->") 
            {
              if ($Matches.course)
              {
                  $course = $Matches.course
                  $trainingMarkdown = get-markdown -trainerId $trainerId -courses @($course)
              }
              else {
                  $trainingMarkdown = get-markdown -trainerId $trainerId
              }
            }
            $card[1].markdown = $markdown -replace "(?s)(?<=<!--SCRUM TRAINING(:\d+)?-->).*(?=<!--/SCRUM TRAINING-->)", $trainingMarkdown
        }
    }

    return $mobiledoc
}

function Update-LexicalNode {
    param(
        [object]$node,
        [string]$trainerId
    )

    if ($node -is [hashtable] -or $node -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($node.type -eq "markdown" -and $node.markdown) {
            $markdown = $node.markdown
            if ($markdown -match "<!--SCRUM TRAINING(:(?<course>\d+))?-->") 
            {
                if ($Matches.course)
                {
                    $course = $Matches.course
                    $trainingMarkdown = get-markdown -trainerId $trainerId -courses @($course)
                }
                else {
                    $trainingMarkdown = get-markdown -trainerId $trainerId
                }
                $node.markdown = $markdown -replace "(?s)(?<=<!--SCRUM TRAINING(:\d+)?-->).*(?=<!--/SCRUM TRAINING-->)", $trainingMarkdown
            }
        }

        if ($node.children -is [array]) {
            foreach ($child in $node.children) {
                Update-LexicalNode -node $child -trainerId $trainerId
            }
        }

        if ($node.root) {
            Update-LexicalNode -node $node.root -trainerId $trainerId
        }
    }
}

function Update-Lexical {
    param(
        [hashtable]$lexical,
        [string]$trainerId
    )

    Update-LexicalNode -node $lexical -trainerId $trainerId

    return $lexical
}

$parts = $token -split ":"
$id = $parts[0]
Write-Output "::add-mask::$id"

$secret = $parts[1]
Write-Output "::add-mask::$secret"

$key = [Convert]::FromHexString($secret)
Write-Output "::add-mask::$key"

$jwttoken = New-Jwt -Header (@{
        "alg" = "HS256"
        "kid" = $id
        "typ" = "JWT"
    } | ConvertTo-Json) -PayloadJson (@{
        "exp" = ([DateTimeOffset](Get-Date).AddMinutes(2)).ToUnixTimeSeconds()
        "iat" = ([DateTimeOffset](Get-Date)).ToUnixTimeSeconds()
        "aud" = "/admin/"
    } | ConvertTo-Json) -Secret $key

Write-Output "::add-mask::$jwttoken"

$headers = @{
    Authorization  = "Ghost $jwttoken"
    "Content-Type" = "application/json"
    "User-Agent" = $userAgent
}

$alltrainingpages = Invoke-RestMethod -Uri "https://scrumbug.ghost.io/ghost/api/admin/pages/" -Method GET -Headers $headers
foreach ($page in $alltrainingpages.pages) {
    $trainingpage = $page
    $uri = "https://scrumbug.ghost.io/ghost/api/admin/pages/$($trainingpage.id)/"
    $trainingPages = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers

    if ($trainingPages.pages[0].mobiledoc -ne $null)
    {
        $mobiledoc = $trainingPages.pages[0].mobiledoc | ConvertFrom-Json -AsHashtable

        $mobiledoc = Update-Mobiledoc -mobiledoc $mobiledoc -trainerId $trainerId

        $mobiledoc = $mobiledoc | ConvertTo-Json -Depth 10
        $original = ($trainingPages.pages[0].mobiledoc | ConvertFrom-Json -AsHashtable) | ConvertTo-Json -Depth 10
    
        if ($original -ne $mobiledoc)
        {
            $body = @{
                "pages" = @(
                    @{
                        "updated_at" = $trainingPages.pages[0].updated_at
                        "mobiledoc"  = $mobiledoc
                    }
                )
            }
            $result = Invoke-RestMethod -Uri $uri -Method PUT -Body ($body | ConvertTo-Json) -Headers $headers
            continue
        }
    }
    elseif ($trainingPages.pages[0].lexical -ne $null)
    {
        $lexical = $trainingPages.pages[0].lexical | ConvertFrom-Json -AsHashtable

        $lexical = Update-Lexical -lexical $lexical -trainerId $trainerId

        $lexical = $lexical | ConvertTo-Json -Depth 100
        $original = ($trainingPages.pages[0].lexical | ConvertFrom-Json -AsHashtable) | ConvertTo-Json -Depth 100
    
        if ($original -ne $lexical)
        {
            $body = @{
                "pages" = @(
                    @{
                        "updated_at" = $trainingPages.pages[0].updated_at
                        "lexical"  = $lexical
                    }
                )
            }
            Write-Host "Updating: $($trainingpage.slug)"
            $result = Invoke-RestMethod -Uri $uri -Method PUT -Body ($body | ConvertTo-Json) -Headers $headers
            continue
        }
    }
        
    Write-Host "Skipping: $($trainingpage.slug)"
}
