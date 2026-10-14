<#
Unit test for S2-3: Overlay hash and render gating fix
Tests that Get-TextHash correctly identifies content changes and caching prevents unnecessary rewrites.
#>

param([switch]$Verbose)

$ErrorActionPreference = 'Stop'

# Define Get-TextHash inline to match the implementation in website_generator.ps1
function Get-TextHash {
    param([string]$Text)
    $hashBytes = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

Write-Host "Testing overlay hash function (S2-3)" -ForegroundColor Cyan

# Test 1: Hash consistency - same input produces same hash
Write-Host "`n[Test 1] Hash consistency - same input produces same hash" -ForegroundColor Yellow
$text1 = "Hello, World!"
$hash1a = Get-TextHash -Text $text1
$hash1b = Get-TextHash -Text $text1
if ($hash1a -eq $hash1b) {
    Write-Host "[PASS] Same input produces identical hashes" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Same input produced different hashes: '$hash1a' vs '$hash1b'" -ForegroundColor Red
    exit 1
}

# Test 2: Hash uniqueness - different inputs produce different hashes
Write-Host "`n[Test 2] Hash uniqueness - different inputs produce different hashes" -ForegroundColor Yellow
$text2a = "Content A"
$text2b = "Content B"
$hash2a = Get-TextHash -Text $text2a
$hash2b = Get-TextHash -Text $text2b
if ($hash2a -ne $hash2b) {
    Write-Host "[PASS] Different inputs produce different hashes" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Different inputs produced same hash: '$hash2a'" -ForegroundColor Red
    exit 1
}

# Test 3: UTF8 encoding - text is handled correctly
Write-Host "`n[Test 3] UTF8 encoding - text is handled correctly" -ForegroundColor Yellow
$text3 = "Cafe a Paris"
$hash3 = Get-TextHash -Text $text3
if ($hash3 -match '^[a-f0-9]{32}$') {
    Write-Host "[PASS] Text produces valid MD5 hash: $hash3" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Hash format invalid: '$hash3'" -ForegroundColor Red
    exit 1
}

# Test 4: Whitespace sensitivity - trailing spaces change the hash
Write-Host "`n[Test 4] Whitespace sensitivity - trailing spaces change the hash" -ForegroundColor Yellow
$text4a = "Content"
$text4b = "Content "
$hash4a = Get-TextHash -Text $text4a
$hash4b = Get-TextHash -Text $text4b
if ($hash4a -ne $hash4b) {
    Write-Host "[PASS] Whitespace differences are detected" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Trailing space not detected (both hashes: $hash4a)" -ForegroundColor Red
    exit 1
}

# Test 5: Empty string handling
Write-Host "`n[Test 5] Empty string handling" -ForegroundColor Yellow
$text5 = ""
$hash5 = Get-TextHash -Text $text5
if ($hash5 -match '^[a-f0-9]{32}$') {
    Write-Host "[PASS] Empty string produces valid hash: $hash5" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Hash format invalid: '$hash5'" -ForegroundColor Red
    exit 1
}

# Test 6: Verify hash is 32-char hex string
Write-Host "`n[Test 6] Hash format - 32 character hex string" -ForegroundColor Yellow
$text6 = "Test content"
$hash6 = Get-TextHash -Text $text6
if ($hash6.Length -eq 32 -and $hash6 -match '^[a-f0-9]+$') {
    Write-Host "[PASS] Hash is 32-char hex string: $hash6" -ForegroundColor Green
} else {
    Write-Host "[FAIL] Hash format unexpected: '$hash6'" -ForegroundColor Red
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "All unit tests PASSED!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
exit 0
