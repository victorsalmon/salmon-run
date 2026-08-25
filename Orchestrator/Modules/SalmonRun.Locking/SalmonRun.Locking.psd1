# Boundary: No credentials — file and namespace locking
@{
    RootModule = 'SalmonRun.Locking.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a7d4e3f2-1b8c-4d5e-9f6a-7b2c3d4e5f6a'
    Author = 'Salmon Run'
    Description = 'File and namespace locking primitives for Interclaw — Lock-File, Unlock-File, Register-Namespace, Remove-NamespaceReservation, lock state tracking, and deadlock detection.'
    PowerShellVersion = '7.0'
    # SalmonRun.Constants and SalmonRun.Core are loaded at runtime (in .psm1) to
    # avoid circular dependency — Core also requires Locking. Do NOT add RequiredModules.
    RequiredModules = @()
    FunctionsToExport = @(
        'Lock-File'
        'Unlock-File'
        'Register-Namespace'
        'Remove-NamespaceReservation'
    )
    AliasesToExport = @(
        'Acquire-FileLock'
        'Release-FileLock'
        'Acquire-NamespaceReservation'
        'Release-NamespaceReservation'
        'Reserve-Namespace'
    )
    PrivateData = @{ PSData = @{ } }
}
