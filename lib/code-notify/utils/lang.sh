#!/bin/bash

# Language / i18n utilities for Code-Notify
# Usage: source this file, then use t() to translate notification strings

LANG_DIR="$HOME/.claude/notifications"
LANG_FILE="$LANG_DIR/lang"

# Get the current language setting
# Returns "en" (default) or "zh"
get_lang() {
    if [[ -f "$LANG_FILE" ]]; then
        local lang
        lang=$(cat "$LANG_FILE" 2>/dev/null || echo "en")
        case "$lang" in
            "zh"|"zh-CN"|"zh_CN"|"cn") echo "zh" ;;
            *) echo "en" ;;
        esac
    else
        echo "en"
    fi
}

# Set the language
set_lang() {
    local lang="${1:-en}"
    case "$lang" in
        "zh"|"zh-CN"|"zh_CN"|"cn") lang="zh" ;;
        *) lang="en" ;;
    esac
    mkdir -p "$LANG_DIR"
    echo "$lang" > "$LANG_FILE"
}

# Translate a key to the current language
# Usage: t <key>
t() {
    local key="$1"
    local lang
    lang=$(get_lang)

    case "$lang" in
        "zh")
            case "$key" in
                # Stop / task complete
                "task_complete")           echo "任务完成" ;;
                "completed_the_task")       echo "已完成任务" ;;
                # Notification / input required
                "input_required")           echo "需要确认" ;;
                "needs_your_input")         echo "需要你的输入" ;;
                # Subagent
                "subagent_started")         echo "子任务启动" ;;
                "started_a_subagent")       echo "启动了子任务" ;;
                "subagent_complete")        echo "子任务完成" ;;
                "subagent_completed")       echo "子任务已完成" ;;
                # Teammate
                "waiting_for_input")        echo "等待输入" ;;
                "teammate_waiting")         echo "队友等待输入" ;;
                # Team tasks
                "task_created")             echo "任务已创建" ;;
                "team_task_created")        echo "团队任务已创建" ;;
                "team_task_complete")       echo "团队任务完成" ;;
                "team_task_completed")      echo "团队任务已完成" ;;
                # Error
                "error")                    echo "出错了" ;;
                "error_occurred")           echo "发生了一个错误" ;;
                # Test
                "notifications_working")    echo "通知功能正常工作！" ;;
                # Usage
                "usage_alert")              echo "用量提醒" ;;
                "usage_changed")            echo "用量发生变化" ;;
                "tokens_reset")             echo "额度重置" ;;
                "tokens_have_reset")        echo "额度已重置，恢复到 100%。" ;;
                # PreToolUse
                "question")                 echo "有问题" ;;
                "is_asking")                echo "正在提问" ;;
                # Default
                "status_update")            echo "状态更新" ;;
                *)
                    # Fallback to English
                    case "$key" in
                        "task_complete")           echo "Task Complete" ;;
                        "completed_the_task")       echo "completed the task" ;;
                        "input_required")           echo "Input Required" ;;
                        "needs_your_input")         echo "needs your input" ;;
                        "subagent_started")         echo "Subagent Started" ;;
                        "started_a_subagent")       echo "started a subagent" ;;
                        "subagent_complete")        echo "Subagent Complete" ;;
                        "subagent_completed")       echo "subagent completed" ;;
                        "waiting_for_input")        echo "Waiting for Input" ;;
                        "teammate_waiting")         echo "teammate is waiting for input" ;;
                        "task_created")             echo "Task Created" ;;
                        "team_task_created")        echo "agent-team task was created" ;;
                        "team_task_complete")       echo "Task Complete" ;;
                        "team_task_completed")      echo "agent-team task completed" ;;
                        "error")                    echo "Error" ;;
                        "error_occurred")           echo "An error occurred" ;;
                        "notifications_working")    echo "Notifications are working!" ;;
                        "usage_alert")              echo "Usage Alert" ;;
                        "usage_changed")            echo "usage changed" ;;
                        "tokens_reset")             echo "Tokens Reset" ;;
                        "tokens_have_reset")        echo "tokens have reset. Usage is back to 100%." ;;
                        "question")                 echo "Question" ;;
                        "is_asking")                echo "is asking a question" ;;
                        "status_update")            echo "Status Update" ;;
                        *)                          echo "$key" ;;
                    esac
                    ;;
            esac
            ;;
        *)
            # English (default)
            case "$key" in
                "task_complete")           echo "Task Complete" ;;
                "completed_the_task")       echo "completed the task" ;;
                "input_required")           echo "Input Required" ;;
                "needs_your_input")         echo "needs your input" ;;
                "subagent_started")         echo "Subagent Started" ;;
                "started_a_subagent")       echo "started a subagent" ;;
                "subagent_complete")        echo "Subagent Complete" ;;
                "subagent_completed")       echo "subagent completed" ;;
                "waiting_for_input")        echo "Waiting for Input" ;;
                "teammate_waiting")         echo "teammate is waiting for input" ;;
                "task_created")             echo "Task Created" ;;
                "team_task_created")        echo "agent-team task was created" ;;
                "team_task_complete")       echo "Task Complete" ;;
                "team_task_completed")      echo "agent-team task completed" ;;
                "error")                    echo "Error" ;;
                "error_occurred")           echo "An error occurred" ;;
                "notifications_working")    echo "Notifications are working!" ;;
                "usage_alert")              echo "Usage Alert" ;;
                "usage_changed")            echo "usage changed" ;;
                "tokens_reset")             echo "Tokens Reset" ;;
                "tokens_have_reset")        echo "tokens have reset. Usage is back to 100%." ;;
                "question")                 echo "Question" ;;
                "is_asking")                echo "is asking a question" ;;
                "status_update")            echo "Status Update" ;;
                *)                          echo "$key" ;;
            esac
            ;;
    esac
}
