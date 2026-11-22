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

function ConvertTo-Base64Url {
    param(
        [byte[]]$bytes
    )

    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-HmacSha256Jwt {
    param(
        [hashtable]$header,
        [hashtable]$payload,
        [byte[]]$secret
    )

    $headerJson = $header | ConvertTo-Json -Compress
    $payloadJson = $payload | ConvertTo-Json -Compress

    $encodedHeader = ConvertTo-Base64Url -bytes ([Text.Encoding]::UTF8.GetBytes($headerJson))
    $encodedPayload = ConvertTo-Base64Url -bytes ([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $signingInput = "$encodedHeader.$encodedPayload"

    $hmac = [System.Security.Cryptography.HMACSHA256]::new($secret)
    try {
        $signature = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($signingInput))
    }
    finally {
        $hmac.Dispose()
    }

    return "$signingInput.$(ConvertTo-Base64Url -bytes $signature)"
}

function Get-Classes {
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
    
    $today = [DateTime]::UtcNow.Date
    $page = 1
    do {
        $body.page = $page
        $result = Invoke-RestMethod -Uri "https://www.scrum.org/api/class-search" -Headers $searchHeaders -Method POST -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 10) -ErrorAction Stop
        $totalItems = 0
        if ($null -eq $result -or $null -eq $result.PSObject.Properties['items'] -or $null -eq $result.items -or
            $null -eq $result.PSObject.Properties['totalItems'] -or
            -not [int]::TryParse([string]$result.totalItems, [ref]$totalItems) -or $totalItems -lt 0) {
            throw 'Scrum.org class search returned invalid pagination or items.'
        }
        $expectedCount = [Math]::Min(20, [Math]::Max(0, $totalItems - (($page - 1) * 20)))
        if (@($result.items).Count -lt $expectedCount) {
            throw "Scrum.org returned an incomplete class search page $page."
        }
        foreach ($course in $result.items) {
            if ([string]::IsNullOrWhiteSpace($course.EndDate)) {
                throw 'Scrum.org returned a class without an end date.'
            }
            $endDate = [DateTime]::Parse($course.EndDate)
            if ($endDate.Date -ge $today) {
                $course
            }
        }
        $page++
    } while (($page - 1) * 20 -lt $totalItems)
}

function Get-ClassDateString {
    param([object]$course)

    $startDate = [DateTime]::Parse($course.StartDate)
    $endDate = [DateTime]::Parse($course.EndDate)
    if ($startDate.Date -eq $endDate.Date) {
        return "$($startDate.Day) $($startDate.ToString('MMM yyyy'))"
    }
    if ($startDate.Year -eq $endDate.Year -and $startDate.Month -eq $endDate.Month) {
        return "$($startDate.Day)-$($endDate.Day) $($endDate.ToString('MMM yyyy'))"
    }
    if ($startDate.Year -eq $endDate.Year) {
        return "$($startDate.Day) $($startDate.ToString('MMM'))-$($endDate.Day) $($endDate.ToString('MMM yyyy'))"
    }
    return "$($startDate.Day) $($startDate.ToString('MMM yyyy'))-$($endDate.Day) $($endDate.ToString('MMM yyyy'))"
}

function Get-TrainingSchedule {
    param(
        [string]$trainerId,
        [string[]]$courses,
        [ValidateSet('markdown', 'html')]
        [string]$format
    )

    $classes = @(Get-Classes -trainerId $trainerId -courses $courses)
    if ($classes.Count -eq 0) {
        return "`n"
    }

    if ($format -eq 'html') {
        $output = "`n<table><thead><tr><th>Course</th><th>Dates</th><th>Language</th><th>Location</th></tr></thead><tbody>`n"
    }
    else {
        $output = "`n| Course | Dates | Language | Location |`n|--------|-------|----------|----------|`n"
    }

    foreach ($course in $classes) {
        if (-not $course.url.StartsWith('/') -or $course.url.StartsWith('//')) {
            throw "Scrum.org returned an invalid class URL: $($course.url)"
        }
        $url = "https://scrum.org$($course.url)"
        $date = Get-ClassDateString -course $course
        if ($format -eq 'html') {
            $url = [System.Net.WebUtility]::HtmlEncode($url)
            $title = [System.Net.WebUtility]::HtmlEncode($course.Title)
            $date = [System.Net.WebUtility]::HtmlEncode($date)
            $language = [System.Net.WebUtility]::HtmlEncode([string]$course.languages[0])
            $location = [System.Net.WebUtility]::HtmlEncode([string]$course.location)
            $output += "<tr><td><a href=`"$url`">$title</a></td><td>$date</td><td>$language</td><td>$location</td></tr>`n"
        }
        else {
            $output += "| [$($course.Title)]($url) | $date | $($course.languages[0]) | $($course.location) |`n"
        }
    }
    if ($format -eq 'html') {
        $output += "</tbody></table>`n"
    }
    return $output
}

function Update-TrainingContent {
    param(
        [string]$content,
        [string]$trainerId,
        [ValidateSet('markdown', 'html')]
        [string]$format
    )

    $pattern = '(?s)(?<start><!-- SCRUM-CLASS-LIST:START -->|<!--SCRUM TRAINING(?::(?<course>\d+))?-->).*?(?<end><!-- SCRUM-CLASS-LIST:END -->|<!--/SCRUM TRAINING-->)'
    $scheduleTrainerId = $trainerId
    $scheduleFormat = $format
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)

        if (($match.Groups['start'].Value -eq '<!-- SCRUM-CLASS-LIST:START -->') -ne
            ($match.Groups['end'].Value -eq '<!-- SCRUM-CLASS-LIST:END -->')) {
            throw 'Mismatched Scrum schedule markers.'
        }
        $course = $match.Groups['course'].Value
        if ($course) {
            $schedule = Get-TrainingSchedule -trainerId $scheduleTrainerId -courses @($course) -format $scheduleFormat
        }
        else {
            $schedule = Get-TrainingSchedule -trainerId $scheduleTrainerId -format $scheduleFormat
        }
        return $match.Groups['start'].Value + $schedule + $match.Groups['end'].Value
    }
    return [regex]::Replace($content, $pattern, $evaluator)
}

function Update-Mobiledoc {
    param(
        [hashtable]$mobiledoc,
        [string]$trainerId
    )

    foreach ($card in $mobiledoc.cards) {
        if ($card[0] -eq "markdown") {
            $card[1].markdown = Update-TrainingContent -content $card[1].markdown -trainerId $trainerId -format markdown
        }
        elseif ($card[0] -eq "html") {
            $card[1].html = Update-TrainingContent -content $card[1].html -trainerId $trainerId -format html
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
            $node.markdown = Update-TrainingContent -content $node.markdown -trainerId $trainerId -format markdown
        }
        elseif ($node.type -eq "html" -and $node.html) {
            $node.html = Update-TrainingContent -content $node.html -trainerId $trainerId -format html
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

function Invoke-GhostRequest {
    param(
        [string]$uri,
        [ValidateSet('GET', 'PUT')]
        [string]$method,
        [string]$body
    )

    $parts = $token -split ':'
    if ($parts.Count -ne 2) {
        throw 'Ghost token must have an id and secret.'
    }
    $id = $parts[0]
    Write-Host "::add-mask::$id"
    $secret = $parts[1]
    Write-Host "::add-mask::$secret"
    $key = [Convert]::FromHexString($secret)
    $jwttoken = New-HmacSha256Jwt -Header @{
            "alg" = "HS256"
            "kid" = $id
            "typ" = "JWT"
        } -Payload @{
            "exp" = ([DateTimeOffset](Get-Date).AddMinutes(2)).ToUnixTimeSeconds()
            "iat" = ([DateTimeOffset](Get-Date)).ToUnixTimeSeconds()
            "aud" = "/admin/"
        } -Secret $key

    Write-Host "::add-mask::$jwttoken"

    $headers = @{
        Authorization  = "Ghost $jwttoken"
        "Content-Type" = "application/json"
        "User-Agent" = $userAgent
    }

    if ($method -eq 'PUT') {
        return Invoke-RestMethod -Uri $uri -Method $method -Body $body -Headers $headers -ErrorAction Stop
    }
    return Invoke-RestMethod -Uri $uri -Method $method -Headers $headers -ErrorAction Stop
}

function Update-GhostSchedules {
    param([string]$trainerId)

    $baseUri = 'https://scrumbug.ghost.io/ghost/api/admin'
    foreach ($type in @('pages', 'posts')) {
        # Snapshot the complete result before edits can change its ordering.
        $items = @()
        $pageNumber = 1
        do {
            $uri = "$baseUri/$type/?limit=100&page=$pageNumber&order=created_at%20asc%2Cid%20asc"
            if ($type -eq 'posts') {
                $uri += '&filter=tag%3Ahash-training'
            }
            $response = Invoke-GhostRequest -uri $uri -method GET
            if ($null -eq $response.meta.pagination -or $null -eq $response.$type) {
                throw "Ghost returned an invalid $type browse response."
            }
            $items += @($response.$type)
            $nextPage = $response.meta.pagination.next
            if ($null -ne $nextPage -and [int]$nextPage -le $pageNumber) {
                throw "Ghost returned an invalid next page for $type."
            }
            $pageNumber = [int]$nextPage
        } while ($null -ne $nextPage)

        foreach ($item in $items) {
            if ([string]::IsNullOrWhiteSpace($item.id)) {
                throw "Ghost returned a $type item without an id."
            }
            $uri = "$baseUri/$type/$($item.id)/"
            $response = Invoke-GhostRequest -uri "$($uri)?formats=lexical,mobiledoc&include=tags" -method GET
            $entry = @($response.$type)[0]
            if ($null -eq $entry -or [string]::IsNullOrWhiteSpace($entry.updated_at)) {
                throw "Ghost returned an invalid $type item for $($item.id)."
            }
            if ($type -eq 'posts') {
                if ($null -eq $entry.tags) {
                    throw "Ghost did not return tags for post $($item.id)."
                }
                if (-not @($entry.tags | Where-Object { $_.slug -eq 'hash-training' }).Count) {
                    Write-Host "Skipping posts/$($item.id): no longer tagged #training."
                    continue
                }
            }

            if ($entry.lexical) {
                $field = 'lexical'
                $content = $entry.lexical | ConvertFrom-Json -AsHashtable
                $original = $content | ConvertTo-Json -Depth 100 -Compress
                $content = Update-Lexical -lexical $content -trainerId $trainerId
            }
            elseif ($entry.mobiledoc) {
                $field = 'mobiledoc'
                $content = $entry.mobiledoc | ConvertFrom-Json -AsHashtable
                $original = $content | ConvertTo-Json -Depth 100 -Compress
                $content = Update-Mobiledoc -mobiledoc $content -trainerId $trainerId
            }
            else {
                Write-Host "Skipping $type/$($item.id): no editable content."
                continue
            }

            $updated = $content | ConvertTo-Json -Depth 100 -Compress
            if ($original -ceq $updated) {
                Write-Host "Skipping $type/$($item.id): no schedule changes."
                continue
            }
            $payload = @{ $type = @(@{ updated_at = $entry.updated_at; $field = $updated }) }
            $body = $payload | ConvertTo-Json -Depth 100 -Compress
            $null = Invoke-GhostRequest -uri $uri -method PUT -body $body
            Write-Host "Updated $type/$($item.id)."
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Update-GhostSchedules -trainerId $trainerId
}
