package dev.gboard.enhancer

internal object FlagOverrideEngine {
    private val writingTrue = hashSetOf(
        "writing_helper", "config_proofread", "writing_tools",
        "writing_helper_on_selected_text", "writing_helper_enable_text_stylization_internal",
        "enable_writing_tools_cooperative_mode", "enable_writing_tools_for_minors",
        "enable_writing_tools_voice_commands", "enable_nga_lab_modeless_smartedit",
        "enable_writing_tools_suggest_style", "enable_writing_tools_my_style",
        "enable_writing_tools_my_style_plus", "enable_writing_tools_my_style_plus_without_screen_context",
        "writing_tools_enable_smart_reply", "writing_tools_v2_enable_p13n",
        "writing_tools_v2_enable_suggested_instructions", "writing_tools_v2_enable_suggested_instructions_toast",
        "writing_tools_enable_streaming_ui", "enable_writing_tools_replace_button",
        "enable_writing_tools_thumb_up_and_down", "writing_tools_context_enable_inline"
    )
    private val modelTrue = hashSetOf(
        "enable_ondevice_recognizer", "force_speech_language_pack_updates",
        "allow_metered_small_speech_pack_downloads", "enable_handwriting_promo"
    )
    private val experimentalTrue = hashSetOf(
        "enable_emojify_model", "enable_emojify_settings_option",
        "enable_agentic_dictation", "nga_enable_mic_button_when_dictation_eligible",
        "mdd_superpack_enabled", "use_mdd_for_superpack"
    )

    fun apply(name: String?, original: Any?, cfg: RuntimeConfig): Any? {
        if (name == null || original == null) return original

        if (cfg.writingTools) {
            if (original is Boolean && name in writingTrue) return true
            if (original is String && (name == "writing_helper_supported_language_tags" || name == "llm_pc_supported_language_tags")) return "*"
            when (name) {
                "writing_tools_v2_backend_type" -> if (original is Long) return when (cfg.backend) {
                    "AICORE" -> 2L
                    "ASTREA" -> 3L
                    else -> 1L
                }
                "writing_tools_enable_hybrid" -> if (original is Boolean) return cfg.backend != "GBOARD_SERVER"
                "enable_on_device_proofread" -> if (original is Boolean) return cfg.backend == "AICORE"
                "nga_lab_modeless_smartedit_regex_version" -> if (original is String && original.isEmpty()) return "v3"
            }
        }

        if (cfg.regionBypass) {
            if (name == "device_country_for_testing" && original is String) return cfg.forcedCountry
            if (name == "agentic_dictation_excluded_language_tags" && original is String) return ""
            if (cfg.experimental && name == "use_jni_results_to_filter_country_flags" && original is Boolean) return false
        }

        if (cfg.modelUnlock) {
            if (original is Boolean && name in modelTrue) return true
            if (name == "disable_ondevice_auto_download" && original is Boolean) return false
            if (name == "handwriting_superpacks_manifest_url_v2" && original is String) return ModelCatalog.HANDWRITING_MANIFEST
            if (name == "speech_superpacks_manifest_url" && original is String) return ModelCatalog.SPEECH_FULL_MANIFEST
            if (name == "speech_superpacks_small_lps_manifest_url" && original is String) return ModelCatalog.SPEECH_SMALL_MANIFEST
        }

        if (cfg.experimental && original is Boolean && name in experimentalTrue) return true
        return original
    }
}
