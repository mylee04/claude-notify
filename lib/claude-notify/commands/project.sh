#!/bin/bash

# Project-specific command handlers for Claude-Notify

# Handle project commands
handle_project_command() {
    local command="${1:-status}"
    shift
    
    case "$command" in
        "on")
            enable_notifications_project "$@"
            ;;
        "off")
            disable_notifications_project "$@"
            ;;
        "status")
            show_project_status "$@"
            ;;
        "init")
            init_project_interactive "$@"
            ;;
        *)
            error "Unknown project command: $command"
            echo "Valid commands: on, off, status, init"
            exit 1
            ;;
    esac
}

# Enable notifications for current project
enable_notifications_project() {
    local project_root=$(get_project_root)
    local project_name=$(get_project_name)
    local project_hooks_dir="$project_root/.claude"
    local project_hooks_file="$project_hooks_dir/hooks.json"
    
    header "${ROCKET} Enabling Notifications for Project: $project_name"
    echo ""
    info "Project location: $project_root"
    
    # Check if already enabled
    if [[ -f "$project_hooks_file" ]]; then
        warning "Project notifications are already enabled"
        info "Config: $project_hooks_file"
        return 0
    fi
    
    # Create .claude directory if needed
    if [[ ! -d "$project_hooks_dir" ]]; then
        info "Creating project configuration directory..."
        mkdir -p "$project_hooks_dir"
    fi
    
    # Get notification script path
    local notify_script=$(get_notify_script)
    
    # Create project-specific hooks
    info "Creating project-specific configuration..."
    cat > "$project_hooks_file" << EOF
{
  "hooks": {
    "stop": {
      "description": "Project-specific notification for $project_name",
      "command": "$notify_script stop completed '$project_name'"
    },
    "notification": {
      "description": "Project-specific input notification for $project_name",
      "command": "$notify_script notification required '$project_name'"
    }
  }
}
EOF
    
    success "Project notifications ENABLED"
    info "Config created at: $project_hooks_file"
    
    # Send test notification
    echo ""
    info "Sending test notification..."
    if [[ -f "$notify_script" ]]; then
        "$notify_script" "test" "completed" "$project_name"
    else
        test_notification "silent"
    fi
    
    echo ""
    dim "Note: Project settings override global settings"
}

# Disable notifications for current project
disable_notifications_project() {
    local project_root=$(get_project_root)
    local project_name=$(get_project_name)
    local project_hooks_file="$project_root/.claude/hooks.json"
    
    header "${MUTE} Disabling Notifications for Project: $project_name"
    echo ""
    
    if [[ ! -f "$project_hooks_file" ]]; then
        warning "No project-specific notifications to disable"
        info "Global settings will apply to this project"
        return 0
    fi
    
    # Backup before removing
    backup_config "$project_hooks_file"
    
    # Remove project hooks
    rm "$project_hooks_file"
    success "Project notifications DISABLED"
    
    # Check if .claude directory is empty and remove if so
    if [[ -d "$project_root/.claude" ]] && [[ -z "$(ls -A "$project_root/.claude")" ]]; then
        rmdir "$project_root/.claude"
    fi
    
    # Show what will happen now
    echo ""
    if is_enabled_globally; then
        info "This project will now use global notification settings"
        status_enabled "Global notifications are ENABLED"
    else
        info "No notifications will be sent for this project"
        status_disabled "Global notifications are DISABLED"
    fi
}

# Show project-specific status
show_project_status() {
    local project_name=$(get_project_name)
    local project_root=$(get_project_root)
    
    header "${FOLDER} Project Notification Status"
    echo ""
    echo "Project: ${BOLD}$project_name${RESET}"
    echo "Location: $project_root"
    echo ""
    
    # Check project status
    if is_enabled_project; then
        status_enabled "Project notifications: ENABLED"
        info "Config: $project_root/.claude/hooks.json"
        echo ""
        dim "Project settings override global settings"
    else
        status_disabled "Project notifications: DISABLED"
        echo ""
        # Show global status
        if is_enabled_globally; then
            info "Using global notification settings"
            status_enabled "Global notifications: ENABLED"
        else
            info "No notifications configured for this project"
            status_disabled "Global notifications: DISABLED"
        fi
    fi
    
    # Git information
    if is_git_repo; then
        echo ""
        dim "Git repository detected"
        local branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        dim "Current branch: $branch"
    fi
}

# Interactive project initialization
init_project_interactive() {
    local project_name=$(get_project_name)
    local project_root=$(get_project_root)
    
    header "${ROCKET} Initialize Notifications for: $project_name"
    echo ""
    echo "This will set up project-specific notifications that override global settings."
    echo ""
    
    # Show current status
    if is_enabled_project; then
        warning "Project notifications are already configured"
        echo ""
        read -p "Reconfigure notifications? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Setup cancelled"
            return 0
        fi
    fi
    
    # Check if git repo
    if is_git_repo; then
        info "Git repository detected"
        read -p "Add .claude/ to .gitignore? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if ! grep -q "^\.claude/$" .gitignore 2>/dev/null; then
                echo ".claude/" >> .gitignore
                success "Added .claude/ to .gitignore"
            else
                info ".claude/ already in .gitignore"
            fi
        fi
    fi
    
    # Enable notifications
    echo ""
    read -p "Enable notifications for this project? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        enable_notifications_project
    else
        info "Setup cancelled"
        echo ""
        echo "You can enable later with:"
        echo "  ${CYAN}cnp on${RESET}"
    fi
}