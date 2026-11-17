#[derive(serde::Deserialize)]
struct ShaderSelection {
    name: String,
    enabled: bool,
}

/// The legacy control command uses bare names and reserves off/list. The
/// structured variant keeps filenames distinct from commands and disables
/// a pack only if that exact pack is still selected.
pub(super) fn change(
    command: &str,
    argument: &str,
    selected: &str,
) -> Result<Option<String>, String> {
    if command == "shader-pack-set" {
        let ShaderSelection { name, enabled } =
            serde_json::from_str(argument).map_err(|error| error.to_string())?;
        // The graphics settings file stores its selection on one trimmed line.
        if name.is_empty() || name.trim() != name || name.contains(['\r', '\n', '\0']) {
            return Err("the shader pack filename cannot be saved".into());
        }
        return Ok(match (enabled, selected == name) {
            (true, false) => Some(name),
            (false, true) => Some(String::new()),
            _ => None,
        });
    }
    Ok(match argument {
        "" | "list" => None,
        "off" => Some(String::new()),
        name => Some(name.to_owned()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn structured_names_are_not_interpreted_as_commands() {
        for name in ["off", "list", "A \"quoted\" shader.zip", "春 shader.zip"] {
            let argument = serde_json::json!({"name": name, "enabled": true}).to_string();
            assert_eq!(
                change("shader-pack-set", &argument, "old")
                    .unwrap()
                    .as_deref(),
                Some(name)
            );
        }
        assert_eq!(change("shader-pack", "list", "old").unwrap(), None);
        assert_eq!(
            change("shader-pack", "off", "old").unwrap(),
            Some(String::new())
        );
    }

    #[test]
    fn disabling_is_conditional_and_unsavable_names_are_refused() {
        let argument = r#"{"name":"A.zip","enabled":false}"#;
        assert_eq!(change("shader-pack-set", argument, "B.zip").unwrap(), None);
        assert_eq!(
            change("shader-pack-set", argument, "A.zip").unwrap(),
            Some(String::new())
        );
        for name in ["", " A.zip", "A.zip ", "A\nB.zip"] {
            let invalid = serde_json::json!({"name": name, "enabled": true}).to_string();
            assert!(change("shader-pack-set", &invalid, "old").is_err());
        }
    }
}
