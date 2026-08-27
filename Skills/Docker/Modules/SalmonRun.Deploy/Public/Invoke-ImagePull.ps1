<#
.SYNOPSIS
    Verifies the official Interclaw Docker base image is available and cleans up stale images.
.DESCRIPTION
    Uses the base image declared in InterclawConstants (InterclawImage) or the ORCHESTRATOR_IMAGE
    environment variable. For ':local' images it verifies the image exists locally; for remote
    images it attempts a docker pull. It then prunes old images keeping only the 2 most recent
    per repository.
.PARAMETER
    This function takes no parameters.
.OUTPUTS
    None.
#>
function Invoke-ImagePull {
    [OutputType([void])]
    param()

    $script:ImageVersion = "local"

    $constants = Get-InterclawConstants
    $OfficialImage = if ($env:ORCHESTRATOR_IMAGE) { $env:ORCHESTRATOR_IMAGE } else { $constants.InterclawImage }
    if ([string]::IsNullOrWhiteSpace($OfficialImage)) {
        throw "Invoke-ImagePull: no base image configured (InterclawConstants.InterclawImage and ORCHESTRATOR_IMAGE are both empty)"
    }

    $ImageRepo = ($OfficialImage -split ':')[0]

    Write-SetupLog "Phase 1: Verifying base image $OfficialImage"
    Write-Information -MessageData "`n[ImagePull] Verifying base image: $OfficialImage" -Tags "WARN"

    try {
        if ($OfficialImage -like '*:local') {
            $LocalInspect = Invoke-NativeCommand { docker image inspect $OfficialImage --format '{{.Id}}' 2>$null }
            if ($LocalInspect.Success) {
                Write-Information -MessageData "  [OK] Local base image found: $OfficialImage" -Tags "INFO"
                Write-SetupLog "Local base image found: $OfficialImage"
            } else {
                Write-SetupLog "FAIL: base image $OfficialImage not found locally" -Level ERROR
                Write-Information -MessageData "  [FAIL] Base image not found locally: $OfficialImage" -Tags "ERROR"
                throw "Base image not found locally: $OfficialImage"
            }
        } else {
            $PullResult = Invoke-NativeCommand { docker pull $OfficialImage 2>&1 | Write-Information -Tags "INFO" }
            if (-not $PullResult.Success) {
                Write-SetupLog "FAIL: docker pull $OfficialImage failed" -Level ERROR
                Write-Information -MessageData "  [FAIL] Docker pull failed: $OfficialImage" -Tags "ERROR"
                throw "Docker pull failed: $OfficialImage"
            }
            Write-SetupLog "Pulled base image: $OfficialImage"
            Write-Information -MessageData "  [OK] Pulled base image: $OfficialImage" -Tags "INFO"
        }

        # --------------------------------------------------------------------------
        # Image cleanup -- keep only the 2 most recent images per base/fleet repository
        # --------------------------------------------------------------------------
        foreach ($ImgRepo in @($ImageRepo, "fleet")) {
            $ImageList = @()
            $LinesResult = Invoke-NativeCommand { docker image ls --format "{{.ID}}" --filter "reference=${ImgRepo}" 2>$null }
            $Lines = if ($LinesResult.Success) { $LinesResult.Output -split "`n" | Select-Object -Unique } else { @() }
            foreach ($Id in $Lines) {
                $Id = $Id.Trim()
                if ([string]::IsNullOrWhiteSpace($Id)) { continue }
                $InspectResult = Invoke-NativeCommand { docker image inspect $Id --format '{{.Created}}' 2>$null }
                $CreatedRaw = if ($InspectResult.Success) { $InspectResult.Output } else { $null }
                if ($CreatedRaw) {
                    $ImageList += [pscustomobject]@{
                        Id      = $Id
                        Created = [datetime]::Parse($CreatedRaw, [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                }
            }

            $Sorted = $ImageList | Sort-Object Created -Descending
            if ($Sorted.Count -gt 2) {
                foreach ($OldImg in ($Sorted | Select-Object -Skip 2)) {
                    Write-Information -MessageData "  [CLEANUP] Removing old ${ImgRepo} image: $($OldImg.Id)" -Tags "INFO"
                    $null = Invoke-NativeCommand { docker image rm -f $OldImg.Id 2>$null }
                }
            }
        }

        # Remove any remaining dangling images (untagged) from previous pulls.
        $DanglingResult = Invoke-NativeCommand { docker image ls --filter "dangling=true" --format "{{.ID}}" 2>$null }
        $DanglingImages = $DanglingResult.Output
        if (-not [string]::IsNullOrWhiteSpace(($DanglingImages -join ""))) {
            Write-Information -MessageData "  [CLEANUP] Removing dangling images..." -Tags "INFO"
            $DanglingImages -split "`n" | ForEach-Object {
                $id = $_.Trim()
                if (-not [string]::IsNullOrWhiteSpace($id)) {
                    $null = Invoke-NativeCommand { docker image rm $id 2>$null }
                }
            }
        }
    }
    catch {
        Write-SetupLog "FAIL: image verify/pull error: $($_.Exception.Message)" -Level ERROR
        Write-Information -MessageData "  [FAIL] Image verify/pull error: $($_.Exception.Message)" -Tags "ERROR"
        throw "Image verify/pull error: $($_.Exception.Message)"
    }
}
