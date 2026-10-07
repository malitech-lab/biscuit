import Foundation

/// Every localisable string in Biscuit, as a checked identifier.
///
/// An enum rather than bare string literals for two reasons: a typo becomes a
/// compile error instead of a raw key shown to a user, and `CaseIterable` lets
/// `L10nCompletenessTests` assert that every key exists in every shipped
/// language. A missing translation then fails CI rather than reaching someone's
/// screen.
///
/// Raw values mirror the structure of the `.strings` files so the two stay
/// readable side by side. Keys carrying `%@`/`%llu` placeholders are marked in
/// the comment, because the argument order is part of the contract with
/// translators.
public enum StringKey: String, CaseIterable, Sendable {
    // MARK: - Device buses

    case busUSB = "bus.usb"
    case busThunderbolt = "bus.thunderbolt"
    case busSDCard = "bus.sd_card"
    case busFireWire = "bus.firewire"
    case busInternal = "bus.internal"
    case busVirtual = "bus.virtual"
    case busUnknown = "bus.unknown"

    // MARK: - Image payloads

    case payloadHybridISO = "payload.hybrid_iso"
    case payloadWindowsInstaller = "payload.windows_installer"
    case payloadRawDiskImage = "payload.raw_disk_image"
    case payloadMacOSInstaller = "payload.macos_installer"
    case payloadNonBootableISO = "payload.non_bootable_iso"

    // MARK: - Write strategies

    case strategyRawImage = "strategy.raw_image"
    case strategyRawImageDetail = "strategy.raw_image.detail"
    case strategyWindowsFAT32 = "strategy.windows_fat32"
    case strategyWindowsFAT32Detail = "strategy.windows_fat32.detail"
    case strategyMacOSInstaller = "strategy.macos_installer"
    case strategyMacOSInstallerDetail = "strategy.macos_installer.detail"
    case strategyEraseOnly = "strategy.erase_only"
    case strategyEraseOnlyDetail = "strategy.erase_only.detail"

    // MARK: - Partition schemes and filesystems

    case schemeGPT = "scheme.gpt"
    case schemeMBR = "scheme.mbr"
    case filesystemFAT32 = "filesystem.fat32"
    case filesystemExFAT = "filesystem.exfat"
    case filesystemHFSPlus = "filesystem.hfs_plus"
    case filesystemAPFS = "filesystem.apfs"

    // MARK: - Job phases

    case phasePreparing = "phase.preparing"
    case phaseUnmounting = "phase.unmounting"
    case phasePartitioning = "phase.partitioning"
    case phaseMounting = "phase.mounting"
    case phaseWriting = "phase.writing"
    case phaseCopying = "phase.copying"
    case phaseSplittingWIM = "phase.splitting_wim"
    case phaseFlushing = "phase.flushing"
    case phaseVerifying = "phase.verifying"
    case phaseFinalising = "phase.finalising"
    case phaseDone = "phase.done"

    // MARK: - Checksum algorithms

    case checksumSHA256 = "checksum.sha256"
    case checksumSHA512 = "checksum.sha512"
    case checksumSHA1 = "checksum.sha1"
    case checksumMD5 = "checksum.md5"

    // MARK: - Errors: privileges and helper

    case errorCancelled = "error.cancelled"
    case errorPrivilegeDenied = "error.privilege_denied"
    case errorPrivilegeDeniedRemedy = "error.privilege_denied.remedy"
    case errorHelperUnavailable = "error.helper_unavailable"
    case errorHelperUnavailableRemedy = "error.helper_unavailable.remedy"
    case errorHelperProtocol = "error.helper_protocol"
    case errorHelperProtocolRemedy = "error.helper_protocol.remedy"
    case errorHelperRejected = "error.helper_rejected"
    case errorHelperRejectedRemedy = "error.helper_rejected.remedy"
    case errorHelperClosedWithoutReply = "error.helper_closed_without_reply"
    case errorHelperConnectionLost = "error.helper_connection_lost"
    case errorHelperConnectionLostRemedy = "error.helper_connection_lost.remedy"
    case errorHelperWorldWritable = "error.helper_world_writable"
    case errorHelperWorldWritableRemedy = "error.helper_world_writable.remedy"
    case errorHelperBusy = "error.helper_busy"
    case errorHelperBusyRemedy = "error.helper_busy.remedy"

    // MARK: - Errors: devices

    /// `%@` = BSD name
    case errorDeviceNotEligible = "error.device_not_eligible"
    case errorDeviceNotEligibleRemedy = "error.device_not_eligible.remedy"
    /// `%@` = BSD name
    case errorDeviceIsSystemDisk = "error.device_is_system_disk"
    case errorDeviceIsSystemDiskRemedy = "error.device_is_system_disk.remedy"
    case errorDeviceTooSmall = "error.device_too_small"
    /// `%1$@` = required, `%2$@` = available
    case errorDeviceTooSmallRemedy = "error.device_too_small.remedy"
    case errorDeviceChanged = "error.device_changed"
    /// `%@` = BSD name
    case errorDeviceChangedRemedy = "error.device_changed.remedy"
    case errorDeviceBusy = "error.device_busy"
    case errorDeviceBusyRemedy = "error.device_busy.remedy"
    case errorDeviceInfoUnavailable = "error.device_info_unavailable"
    case errorDeviceListUnreadable = "error.device_list_unreadable"
    case errorDeviceOpenFailed = "error.device_open_failed"
    case errorDeviceOpenFailedBusyRemedy = "error.device_open_failed.busy_remedy"
    case errorDeviceOpenFailedRemedy = "error.device_open_failed.remedy"
    case errorDeviceAccessDenied = "error.device_access_denied"

    // MARK: - Errors: writing and verifying

    case errorWriteFailed = "error.write_failed"
    case errorWriteFailedRemedy = "error.write_failed.remedy"
    /// `%llu` = byte offset
    case errorVerificationFailed = "error.verification_failed"
    case errorVerificationFailedRemedy = "error.verification_failed.remedy"
    case errorDeviceShorterThanImage = "error.device_shorter_than_image"
    case errorDeviceShorterThanImageRemedy = "error.device_shorter_than_image.remedy"
    case errorNoSpaceLeft = "error.no_space_left"
    case errorNoSpaceLeftRemedy = "error.no_space_left.remedy"
    /// `%@` = file name
    case errorFileTooLargeForFilesystem = "error.file_too_large_for_filesystem"
    case errorFileTooLargeForFilesystemRemedy = "error.file_too_large_for_filesystem.remedy"
    case errorPartitioningFailed = "error.partitioning_failed"
    case errorPartitioningFailedRemedy = "error.partitioning_failed.remedy"
    case errorMountFailed = "error.mount_failed"
    case errorMountFailedRemedy = "error.mount_failed.remedy"
    case errorMountNotAppearing = "error.mount_not_appearing"
    case errorMountNotAppearingRemedy = "error.mount_not_appearing.remedy"
    case errorImageUnmountable = "error.image_unmountable"
    case errorImageNoFilesystem = "error.image_no_filesystem"
    case errorImageDetached = "error.image_detached"

    // MARK: - Errors: copying

    /// `%@` = file name
    case errorCopyReadFailed = "error.copy_read_failed"
    /// `%@` = file name
    case errorCopyWriteFailed = "error.copy_write_failed"
    /// `%@` = file name
    case errorCopySourceUnreadable = "error.copy_source_unreadable"
    /// `%@` = file name
    case errorCopyTargetUnwritable = "error.copy_target_unwritable"
    case errorCopyNameTooLongRemedy = "error.copy_name_too_long.remedy"
    case errorCopySourceUnlistable = "error.copy_source_unlistable"
    case errorCopyUnexpectedPath = "error.copy_unexpected_path"

    // MARK: - Errors: sources

    case errorSourceMissing = "error.source_missing"
    case errorSourceUnreadable = "error.source_unreadable"
    case errorSourceUnreadableRemedy = "error.source_unreadable.remedy"
    case errorSourceGoneRemedy = "error.source_gone.remedy"
    case errorSourceTooSmall = "error.source_too_small"
    case errorSourceEmpty = "error.source_empty"
    case errorSourceNotRegularFile = "error.source_not_regular_file"
    case errorSourceOpenDenied = "error.source_open_denied"
    case errorSourceOpenDeniedRemedy = "error.source_open_denied.remedy"
    case errorSourcePathNotAllowed = "error.source_path_not_allowed"
    case errorSourcePathNotAllowedRemedy = "error.source_path_not_allowed.remedy"
    case errorSourcePathInvalid = "error.source_path_invalid"
    case errorNotAMacOSInstaller = "error.not_a_macos_installer"
    case errorNotAMacOSInstallerRemedy = "error.not_a_macos_installer.remedy"
    case errorInstallerOutsideApplications = "error.installer_outside_applications"
    /// `%@` = file name
    case errorInstallerOutsideApplicationsRemedy = "error.installer_outside_applications.remedy"

    // MARK: - Errors: Windows media

    case errorAnswerTemplateArchitecture = "error.answer_template_architecture"
    case errorAnswerTemplateInvalid = "error.answer_template_invalid"
    case errorWimMetadataUnreadable = "error.wim_metadata_unreadable"
    case errorWimMetadataCompressed = "error.wim_metadata_compressed"
    case errorWimMetadataCompressedRemedy = "error.wim_metadata_compressed.remedy"
    case errorWimToolRejected = "error.wim_tool_rejected"
    case errorWimToolRejectedRemedy = "error.wim_tool_rejected.remedy"
    case errorWimToolMissing = "error.wim_tool_missing"
    case errorWimToolMissingRemedy = "error.wim_tool_missing.remedy"
    case errorWimSplitFailed = "error.wim_split_failed"
    case errorWimSplitFailedRemedy = "error.wim_split_failed.remedy"
    /// `%@` = file name
    case errorWimConvertFailed = "error.wim_convert_failed"
    case errorWimNoPartsProduced = "error.wim_no_parts_produced"
    case errorMediaIncomplete = "error.media_incomplete"
    /// `%@` = comma-separated list of missing files
    case errorMediaIncompleteRemedy = "error.media_incomplete.remedy"
    case errorInstallImageMissing = "error.install_image_missing"
    case errorInstallImageMissingRemedy = "error.install_image_missing.remedy"
    case errorCreateInstallMediaFailed = "error.createinstallmedia_failed"
    case errorCreateInstallMediaMissing = "error.createinstallmedia_missing"
    case errorCreateInstallMediaMissingRemedy = "error.createinstallmedia_missing.remedy"
    case errorInstallerTooSmallRemedy = "error.installer_too_small.remedy"
    case errorInstallerDamagedRemedy = "error.installer_damaged.remedy"
    case errorInstallerBusyRemedy = "error.installer_busy.remedy"

    // MARK: - Errors: catalogue

    case errorCatalogueUnreachable = "error.catalogue_unreachable"
    case errorCatalogueInvalid = "error.catalogue_invalid"
    case errorCatalogueEmpty = "error.catalogue_empty"
    case errorCatalogueVersionUnsupported = "error.catalogue_version_unsupported"
    case errorCatalogueVersionUnsupportedRemedy = "error.catalogue_version_unsupported.remedy"
    case errorCatalogueSignatureMissing = "error.catalogue_signature_missing"
    case errorCatalogueSignatureMissingRemedy = "error.catalogue_signature_missing.remedy"
    case errorCatalogueNoKey = "error.catalogue_no_key"
    case errorCatalogueNoKeyRemedy = "error.catalogue_no_key.remedy"
    case errorDownloadChecksumMismatch = "error.download_checksum_mismatch"
    case errorDownloadChecksumMismatchRemedy = "error.download_checksum_mismatch.remedy"
    case errorImageChecksumMismatch = "error.image_checksum_mismatch"
    case errorImageChecksumMismatchRemedy = "error.image_checksum_mismatch.remedy"

    // MARK: - Errors: macOS installers

    case errorMacOSListFailed = "error.macos_list_failed"
    case errorMacOSListFailedRemedy = "error.macos_list_failed.remedy"
    case errorMacOSNoInstallers = "error.macos_no_installers"
    case errorMacOSNoInstallersRemedy = "error.macos_no_installers.remedy"
    case errorMacOSFetchFailed = "error.macos_fetch_failed"
    case errorMacOSFetchNoSpaceRemedy = "error.macos_fetch_no_space.remedy"
    case errorMacOSFetchUnavailableRemedy = "error.macos_fetch_unavailable.remedy"
    case errorMacOSInstallerNotFound = "error.macos_installer_not_found"
    case errorMacOSInstallerNotFoundRemedy = "error.macos_installer_not_found.remedy"

    // MARK: - Errors: compression

    case errorDecompressionFailed = "error.decompression_failed"
    case errorDecompressionFailedRemedy = "error.decompression_failed.remedy"
    case errorDecompressionTruncatedRemedy = "error.decompression_truncated.remedy"
    case errorDecompressionCorrupted = "error.decompression_corrupted"
    /// `%@` = format name
    case errorCompressionUnsupported = "error.compression_unsupported"
    case errorCompressionUnsupportedRemedy = "error.compression_unsupported.remedy"

    // MARK: - Errors: answer file

    case errorAnswerFileUnreadable = "error.answer_file_unreadable"
    case errorAnswerFileRejected = "error.answer_file_rejected"
    case errorAnswerFileWriteFailed = "error.answer_file_write_failed"
    case errorAnswerFileWrongStrategy = "error.answer_file_wrong_strategy"
    case errorAnswerFileMissingAfterWrite = "error.answer_file_missing_after_write"
    case errorAnswerFileMissingAfterWriteRemedy = "error.answer_file_missing_after_write.remedy"

    // MARK: - Errors: updates

    case errorUpdateDisabled = "error.update_disabled"
    case errorUpdateDisabledRemedy = "error.update_disabled.remedy"
    case errorUpdateNoKey = "error.update_no_key"
    case errorUpdateNoKeyRemedy = "error.update_no_key.remedy"
    case errorUpdateKeyInvalid = "error.update_key_invalid"
    case errorUpdateKeyNotEd25519 = "error.update_key_not_ed25519"
    case errorSignatureWrongLength = "error.signature_wrong_length"
    case errorSignatureInvalid = "error.signature_invalid"
    case errorSignatureInvalidRemedy = "error.signature_invalid.remedy"
    case errorSignatureMissing = "error.signature_missing"
    case errorSignatureMissingRemedy = "error.signature_missing.remedy"
    case errorArchiveUnreadable = "error.archive_unreadable"
    case errorArchiveNoApp = "error.archive_no_app"
    case errorArchiveExtractFailed = "error.archive_extract_failed"
    case errorUpdateNoExecutable = "error.update_no_executable"
    case errorUpdateNoHelper = "error.update_no_helper"
    case errorUpdateInfoPlistUnreadable = "error.update_info_plist_unreadable"
    case errorUpdateVersionMismatch = "error.update_version_mismatch"
    case errorUpdateNotNewer = "error.update_not_newer"
    case errorUpdateManualOnly = "error.update_manual_only"
    /// `%@` = directory path
    case errorUpdateManualOnlyRemedy = "error.update_manual_only.remedy"
    case errorUpdateBadRepository = "error.update_bad_repository"
    case errorUpdateDraftRelease = "error.update_draft_release"
    case errorUpdateNoArchive = "error.update_no_archive"
    case errorDownloadFailed = "error.download_failed"
    /// `%d` = HTTP status code
    case errorDownloadHTTPStatus = "error.download_http_status"
    case errorDownloadRetryRemedy = "error.download_retry.remedy"
    /// `%@` = repository
    case errorDownloadNoReleaseRemedy = "error.download_no_release.remedy"
    case errorDownloadNoHTTPResponse = "error.download_no_http_response"

    // MARK: - Errors: generic

    case errorInternal = "error.internal"
    /// `%@` = operation name
    case errorPosixOperationFailed = "error.posix_operation_failed"
    case errorAllocationFailed = "error.allocation_failed"
    case errorFileSizeUnavailable = "error.file_size_unavailable"
    case errorDiskArbitrationUnavailable = "error.disk_arbitration_unavailable"
    case errorDiskArbitrationUnavailableRemedy = "error.disk_arbitration_unavailable.remedy"
    case errorTokenWriteFailed = "error.token_write_failed"

    // MARK: - Detection notes (shown under the selected source)

    case noteHybridMBR = "note.hybrid_mbr"
    case noteGPTHeader = "note.gpt_header"
    case noteNoPartitionTable = "note.no_partition_table"
    case noteFilesystemUnreadable = "note.filesystem_unreadable"
    case noteNoBootSector = "note.no_boot_sector"
    case noteUEFIOnly = "note.uefi_only"
    /// `%@` = format name
    case noteCompressedSupported = "note.compressed_supported"
    /// `%@` = expanded size
    case noteExpandsTo = "note.expands_to"
    /// `%@` = estimated expanded size
    case noteExpandsToApproximately = "note.expands_to_approximately"
    case noteExpandedSizeUnknown = "note.expanded_size_unknown"
    case noteFitsFAT32 = "note.fits_fat32"
    /// `%@` = comma-separated file names with sizes
    case noteExceedsFAT32 = "note.exceeds_fat32"
    case noteWillSplitWIM = "note.will_split_wim"
    case noteWillConvertESD = "note.will_convert_esd"
    case noteWindowsImageWithoutBootFiles = "note.windows_image_without_boot_files"
    /// `%1$@` = generation, `%2$@` = version
    case noteWindowsVersion = "note.windows_version"
    /// `%@` = architecture
    case noteWindowsArchitecture = "note.windows_architecture"
    /// `%@` = architecture
    case noteWindowsArchitectureUnusual = "note.windows_architecture_unusual"
    /// `%@` = edition list
    case noteWindowsEditions = "note.windows_editions"
    /// `%@` = language list
    case noteWindowsLanguages = "note.windows_languages"
    /// `%1$d` = part, `%2$d` = total
    case noteWindowsSplitSet = "note.windows_split_set"
    /// `%@` = compression name
    case noteSolidWIMCannotSplit = "note.solid_wim_cannot_split"
    /// `%1$d` = file count, `%2$@` = expanded size
    case noteContentSummary = "note.content_summary"
    /// `%@` = installer version
    case noteInstallerVersion = "note.installer_version"
    case noteUsesCreateInstallMedia = "note.uses_createinstallmedia"

    // MARK: - Progress detail (shown next to the progress bar)

    case detailValidatingTarget = "detail.validating_target"
    /// `%@` = BSD name
    case detailUnmounting = "detail.unmounting"
    case detailWipingSignatures = "detail.wiping_signatures"
    /// `%@` = filesystem name
    case detailFormatting = "detail.formatting"
    case detailWaitingForMount = "detail.waiting_for_mount"
    /// `%@` = device path
    case detailWritingTo = "detail.writing_to"
    case detailVerifying = "detail.verifying"
    case detailFlushing = "detail.flushing"
    /// `%d` = file count
    case detailCopyingFiles = "detail.copying_files"
    case detailSplittingWIM = "detail.splitting_wim"
    case detailConvertingESD = "detail.converting_esd"
    case detailCreateInstallMediaRunning = "detail.createinstallmedia_running"
    case detailFinished = "detail.finished"

    // MARK: - Job warnings

    case warningNoByteVerificationFileCopy = "warning.no_byte_verification_file_copy"
    case warningNoByteVerificationInstaller = "warning.no_byte_verification_installer"
    case warningCancelledMediaIncomplete = "warning.cancelled_media_incomplete"
    case warningEjectFailed = "warning.eject_failed"
    case noticeEjected = "notice.ejected"

    // MARK: - User interface: chrome and actions

    case appTagline = "ui.app_tagline"
    case actionRefreshDevices = "ui.action.refresh_devices"
    case actionRefreshDevicesShortcut = "ui.action.refresh_devices_shortcut"
    case actionCopyLog = "ui.action.copy_log"
    case actionCheckForUpdates = "ui.action.check_for_updates"
    case actionCancel = "ui.action.cancel"
    case actionReset = "ui.action.reset"
    case actionWrite = "ui.action.write"
    case actionErase = "ui.action.erase"
    case menuDisks = "ui.menu.disks"
    case statusRunning = "ui.status.running"
    case statusCancelling = "ui.status.cancelling"

    // MARK: - User interface: source step

    case sourceSectionTitle = "ui.source.title"
    case sourceSectionSubtitle = "ui.source.subtitle"
    case sourceAnalysing = "ui.source.analysing"
    case sourceDropHere = "ui.source.drop_here"
    case sourceChooseFile = "ui.source.choose_file"
    case sourceDropAccessibility = "ui.source.drop_accessibility"
    case sourceRemove = "ui.source.remove"
    /// `%@` = publisher
    case sourceFromCatalogue = "ui.source.from_catalogue"
    case sourceDigestWillBeChecked = "ui.source.digest_will_be_checked"
    case sourceNotBootable = "ui.source.not_bootable"
    case sourceWimlibMissing = "ui.source.wimlib_missing"
    /// `%@` = size of install.wim
    case sourceWimlibMissingDetail = "ui.source.wimlib_missing_detail"

    // MARK: - User interface: catalogue

    case catalogueTitle = "ui.catalogue.title"
    case catalogueSubtitle = "ui.catalogue.subtitle"
    case catalogueOpen = "ui.catalogue.open"
    case catalogueRefresh = "ui.catalogue.refresh"
    case catalogueLoading = "ui.catalogue.loading"
    case catalogueRetry = "ui.catalogue.retry"
    case catalogueDownload = "ui.catalogue.download"
    case catalogueSelectPrompt = "ui.catalogue.select_prompt"
    case catalogueVerifying = "ui.catalogue.verifying"
    case catalogueOffline = "ui.catalogue.offline"
    /// `%@` = date of the cached copy
    case catalogueOfflineDetail = "ui.catalogue.offline_detail"
    /// `%@` = bytes already present
    case catalogueResumed = "ui.catalogue.resumed"
    case catalogueProvenanceSignature = "ui.catalogue.provenance.signature"
    case catalogueProvenanceChecksum = "ui.catalogue.provenance.checksum"
    case catalogueProvenanceNone = "ui.catalogue.provenance.none"
    case catalogueCacheSize = "ui.catalogue.cache_size"
    case catalogueClearCache = "ui.catalogue.clear_cache"
    case catalogueCacheFooter = "ui.catalogue.cache_footer"
    case catalogueTabImages = "ui.catalogue.tab.images"
    case catalogueTabMacOS = "ui.catalogue.tab.macos"
    case catalogueMacOSLoading = "ui.catalogue.macos.loading"
    case catalogueMacOSTrust = "ui.catalogue.macos.trust"
    case catalogueMacOSDeferred = "ui.catalogue.macos.deferred"
    case catalogueMacOSFetching = "ui.catalogue.macos.fetching"
    /// `%@` = download size
    case catalogueMacOSSizeHint = "ui.catalogue.macos.size_hint"
    case catalogueTabWindows = "ui.catalogue.tab.windows"
    case answerTemplateOpen = "ui.answer_template.open"
    case answerTemplateTitle = "ui.answer_template.title"
    case answerTemplateIntro = "ui.answer_template.intro"
    case answerTemplateBypassHardware = "ui.answer_template.bypass_hardware"
    case answerTemplateBypassHardwareDetail = "ui.answer_template.bypass_hardware.detail"
    case answerTemplateBypassConsequence = "ui.answer_template.bypass_consequence"
    case answerTemplateBypassAccount = "ui.answer_template.bypass_account"
    case answerTemplateBypassAccountDetail = "ui.answer_template.bypass_account.detail"
    case answerTemplateSkipPages = "ui.answer_template.skip_pages"
    case answerTemplateDeclineTelemetry = "ui.answer_template.decline_telemetry"
    case answerTemplateAccountName = "ui.answer_template.account_name"
    case answerTemplateAccountPassword = "ui.answer_template.account_password"
    case answerTemplatePasswordWarning = "ui.answer_template.password_warning"
    case answerTemplateGenerate = "ui.answer_template.generate"
    case answerTemplateGenerated = "ui.answer_template.generated"
    /// `%@` = architecture
    case answerTemplateArchitecture = "ui.answer_template.architecture"
    case windowsAudiencePC = "ui.windows.audience.pc"
    case windowsAudienceARM = "ui.windows.audience.arm"
    case windowsAudienceLegacy = "ui.windows.audience.legacy"
    case windowsWhyNoDownload = "ui.windows.why_no_download"
    case windowsStepEdition = "ui.windows.step.edition"
    case windowsStepLanguage = "ui.windows.step.language"
    case windowsStepDownload = "ui.windows.step.download"
    case windowsStepDrop = "ui.windows.step.drop"
    case windowsOpenPage = "ui.windows.open_page"
    case windowsPageHint = "ui.windows.page_hint"

    // MARK: - User interface: target step

    case targetSectionTitle = "ui.target.title"
    case targetSectionSubtitle = "ui.target.subtitle"
    case targetNoneAttached = "ui.target.none_attached"
    case targetNoneAttachedHint = "ui.target.none_attached_hint"
    /// `%d` = number of unusable disks
    case targetBlockedCount = "ui.target.blocked_count"
    case targetBadgeTooSmall = "ui.target.badge_too_small"
    case targetBadgeVeryLarge = "ui.target.badge_very_large"
    case targetBlockedSystemDisk = "ui.target.blocked.system_disk"
    case targetBlockedReadOnly = "ui.target.blocked.read_only"
    case targetBlockedInternal = "ui.target.blocked.internal"
    case targetBlockedVirtual = "ui.target.blocked.virtual"
    case targetBlockedThunderbolt = "ui.target.blocked.thunderbolt"
    case targetBlockedNoMedia = "ui.target.blocked.no_media"
    case targetBlockedNotRemovable = "ui.target.blocked.not_removable"

    // MARK: - User interface: options step

    case optionsSectionTitle = "ui.options.title"
    case optionsMethod = "ui.options.method"
    case optionsVolumeName = "ui.options.volume_name"
    case optionsVolumeNameRawHint = "ui.options.volume_name_raw_hint"
    /// `%@` = sanitised label
    case optionsVolumeNameAdjusted = "ui.options.volume_name_adjusted"
    case optionsFilesystem = "ui.options.filesystem"
    case optionsPartitionScheme = "ui.options.partition_scheme"
    case optionsVerify = "ui.options.verify"
    case optionsVerifyRawHint = "ui.options.verify.raw_hint"
    case optionsVerifyFileCopyHint = "ui.options.verify.file_copy_hint"
    case optionsVerifyInstallerHint = "ui.options.verify.installer_hint"
    case optionsVerifyEraseHint = "ui.options.verify.erase_hint"
    case optionsEject = "ui.options.eject"

    // MARK: - User interface: blockers

    case blockerSelectTarget = "ui.blocker.select_target"
    case blockerSelectSource = "ui.blocker.select_source"
    case blockerSystemDisk = "ui.blocker.system_disk"
    case blockerReadOnly = "ui.blocker.read_only"
    case blockerNoBootableMethod = "ui.blocker.no_bootable_method"
    case blockerMethodMismatch = "ui.blocker.method_mismatch"
    /// `%1$@` = required, `%2$@` = available
    case blockerTooSmall = "ui.blocker.too_small"

    // MARK: - User interface: answer file

    case answerFileSectionTitle = "ui.answer_file.title"
    case answerFileSectionSubtitle = "ui.answer_file.subtitle"
    case answerFileDropHere = "ui.answer_file.drop_here"
    case answerFileChoose = "ui.answer_file.choose"
    case answerFileRemove = "ui.answer_file.remove"
    case answerFileWillBeRenamed = "ui.answer_file.will_be_renamed"
    case answerFileSecretsWarning = "ui.answer_file.secrets_warning"
    case answerFileSecretsDetail = "ui.answer_file.secrets_detail"
    case answerFileFindingNotXML = "ui.answer_file.finding.not_xml"
    /// `%@` = root element found
    case answerFileFindingWrongRoot = "ui.answer_file.finding.wrong_root"
    case answerFileFindingMissingNamespace = "ui.answer_file.finding.missing_namespace"
    /// `%@` = file size
    case answerFileFindingTooLarge = "ui.answer_file.finding.too_large"
    case answerFileFindingEmpty = "ui.answer_file.finding.empty"
    case answerFileAccessibility = "ui.answer_file.accessibility"
    case blockerAnswerFileInvalid = "ui.blocker.answer_file_invalid"
    case confirmFieldAnswerFile = "ui.confirm.field.answer_file"

    // MARK: - User interface: confirmation

    case confirmTitleErase = "ui.confirm.title_erase"
    case confirmTitleWrite = "ui.confirm.title_write"
    case confirmIrreversible = "ui.confirm.irreversible"
    case confirmSectionTarget = "ui.confirm.section_target"
    case confirmSectionOperation = "ui.confirm.section_operation"
    case confirmDataLoss = "ui.confirm.data_loss"
    case confirmFieldDevice = "ui.confirm.field.device"
    case confirmFieldCapacity = "ui.confirm.field.capacity"
    case confirmFieldConnection = "ui.confirm.field.connection"
    case confirmFieldIdentifier = "ui.confirm.field.identifier"
    case confirmFieldVolumes = "ui.confirm.field.volumes"
    case confirmFieldMethod = "ui.confirm.field.method"
    case confirmFieldSource = "ui.confirm.field.source"
    case confirmFieldSize = "ui.confirm.field.size"
    case confirmFieldFilesystem = "ui.confirm.field.filesystem"
    case confirmFieldScheme = "ui.confirm.field.scheme"
    case confirmFieldName = "ui.confirm.field.name"
    case confirmFieldVerification = "ui.confirm.field.verification"
    case confirmVerificationByteForByte = "ui.confirm.verification.byte_for_byte"
    case confirmVerificationNotApplicable = "ui.confirm.verification.not_applicable"

    // MARK: - User interface: progress

    case progressSectionTitle = "ui.progress.title"
    case progressAuthorisationTitle = "ui.progress.authorisation_title"
    case progressAwaitingAdmin = "ui.progress.awaiting_admin"
    case progressAwaitingAdminDetail = "ui.progress.awaiting_admin_detail"
    case progressCancelling = "ui.progress.cancelling"
    case progressCancellingDetail = "ui.progress.cancelling_detail"
    case progressDoNotUnplug = "ui.progress.do_not_unplug"
    /// `%1$@` = device name, `%2$@` = BSD name
    case progressDoNotUnplugDetail = "ui.progress.do_not_unplug_detail"
    case progressStatWritten = "ui.progress.stat.written"
    case progressStatSpeed = "ui.progress.stat.speed"
    case progressStatRemaining = "ui.progress.stat.remaining"
    /// `%1$d` = step number, `%2$d` = total steps, `%3$@` = phase name
    case progressStepAccessibility = "ui.progress.step_accessibility"

    // MARK: - User interface: outcome

    case outcomeTitleDone = "ui.outcome.title_done"
    case outcomeTitleFailed = "ui.outcome.title_failed"
    case outcomeErased = "ui.outcome.erased"
    case outcomeMacOSReady = "ui.outcome.macos_ready"
    case outcomeWindowsReady = "ui.outcome.windows_ready"
    case outcomeImageWritten = "ui.outcome.image_written"
    /// `%@` = duration
    case outcomeDuration = "ui.outcome.duration"
    /// `%@` = byte count
    case outcomeTransferred = "ui.outcome.transferred"
    case outcomeVerified = "ui.outcome.verified"
    case outcomeTechnicalDetails = "ui.outcome.technical_details"
    case outcomeCopyBrewCommand = "ui.outcome.copy_brew_command"
    case outcomeWindowsBootHint = "ui.outcome.windows_boot_hint"

    // MARK: - User interface: log pane

    case logTitle = "ui.log.title"
    case logFilterAll = "ui.log.filter.all"
    case logFilterInfo = "ui.log.filter.info"
    case logFilterWarnings = "ui.log.filter.warnings"
    case logFilterErrors = "ui.log.filter.errors"
    case logFollow = "ui.log.follow"
    case logCopyTooltip = "ui.log.copy_tooltip"

    // MARK: - User interface: updates

    case updateAvailableTitle = "ui.update.available_title"
    /// `%@` = version
    case updateAvailableVersion = "ui.update.available_version"
    /// `%1$@` = installed version, `%2$@` = download size
    case updateAvailableSubtitle = "ui.update.available_subtitle"
    case updateActionInstall = "ui.update.action_install"
    case updateChanges = "ui.update.changes"
    case updateDownloadingTitle = "ui.update.downloading_title"
    case updateVerifyingTitle = "ui.update.verifying_title"
    case updateVerifyingDetail = "ui.update.verifying_detail"
    case updateReadyTitle = "ui.update.ready_title"
    /// `%@` = version
    case updateReadyDetail = "ui.update.ready_detail"
    case updateReadySubtitle = "ui.update.ready_subtitle"
    case updateActionRelaunch = "ui.update.action_relaunch"
    /// `%@` = error message
    case updateFailedBanner = "ui.update.failed_banner"

    // MARK: - User interface: settings

    case settingsTabGeneral = "ui.settings.tab.general"
    case settingsTabUpdates = "ui.settings.tab.updates"
    case settingsTabDiagnostics = "ui.settings.tab.diagnostics"
    case settingsLanguage = "ui.settings.language"
    case settingsLanguageSystem = "ui.settings.language.system"
    case settingsLanguageHint = "ui.settings.language.hint"
    case settingsVerifyFooter = "ui.settings.verify_footer"
    case settingsAutoCheck = "ui.settings.auto_check"
    case settingsLastCheck = "ui.settings.last_check"
    case settingsNever = "ui.settings.never"
    case settingsCheckNow = "ui.settings.check_now"
    /// `%@` = repository
    case settingsUpdateSource = "ui.settings.update_source"
    case settingsNoSigningKey = "ui.settings.no_signing_key"
    case settingsSigningExplained = "ui.settings.signing_explained"
    case settingsEnvironment = "ui.settings.environment"
    case settingsArchitecture = "ui.settings.architecture"
    case settingsHelperConnected = "ui.settings.helper_connected"
    case settingsYes = "ui.settings.yes"
    case settingsNo = "ui.settings.no"
    case settingsNotFound = "ui.settings.not_found"
    case settingsCopyDiagnostics = "ui.settings.copy_diagnostics"
    case settingsDiagnosticsFooter = "ui.settings.diagnostics_footer"

    /// Shown in the macOS authorisation dialog, so it must explain *why* root
    /// is needed — it is the one moment the user is asked to trust the app.
    case privilegePrompt = "ui.privilege.prompt"

    // MARK: - User interface: startup warnings

    /// `%@` = helper file name
    case startupHelperMissing = "ui.startup.helper_missing"
    case startupWimlibMissing = "ui.startup.wimlib_missing"
    case startupDevelopmentMode = "ui.startup.development_mode"

    /// Keys that take at least one format argument. Used by the completeness
    /// test to check that translations keep their placeholders.
    public static let parameterised: Set<StringKey> = [
        .errorDeviceNotEligible, .errorDeviceIsSystemDisk, .errorDeviceTooSmallRemedy,
        .errorDeviceChangedRemedy, .errorVerificationFailed,
        .errorFileTooLargeForFilesystem, .errorCopyReadFailed, .errorCopyWriteFailed,
        .errorCopySourceUnreadable, .errorCopyTargetUnwritable,
        .errorInstallerOutsideApplicationsRemedy,
        .errorWimConvertFailed, .errorMediaIncompleteRemedy,
        .errorUpdateManualOnlyRemedy, .errorDownloadHTTPStatus,
        .errorDownloadNoReleaseRemedy, .errorPosixOperationFailed,
        .noteExceedsFAT32, .noteContentSummary, .noteInstallerVersion,
        .detailUnmounting, .detailFormatting, .detailWritingTo, .detailCopyingFiles,
        .sourceWimlibMissingDetail, .targetBlockedCount, .optionsVolumeNameAdjusted,
        .blockerTooSmall, .progressDoNotUnplugDetail, .progressStepAccessibility,
        .outcomeDuration, .outcomeTransferred, .updateAvailableVersion,
        .updateAvailableSubtitle, .updateReadyDetail, .updateFailedBanner,
        .settingsUpdateSource, .startupHelperMissing,
        .answerFileFindingWrongRoot, .answerFileFindingTooLarge,
        .catalogueOfflineDetail, .catalogueResumed, .catalogueCacheSize,
        .sourceFromCatalogue, .catalogueMacOSSizeHint,
        .noteWindowsVersion, .noteWindowsArchitecture, .noteWindowsArchitectureUnusual,
        .noteWindowsEditions, .noteWindowsLanguages, .noteWindowsSplitSet,
        .noteSolidWIMCannotSplit, .answerTemplateArchitecture,
        .errorCompressionUnsupported, .noteCompressedSupported,
        .noteExpandsTo, .noteExpandsToApproximately
    ]
}
