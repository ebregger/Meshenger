import statistics
import math

from tools.stress_console import format_data_rate


def mean_latency_confidence(values, target_precision_s=0.01):
    """Return a large-sample 95% CI and iid sample-size estimate for latency."""
    if not math.isfinite(target_precision_s) or target_precision_s <= 0:
        raise ValueError("target_precision_s must be finite and positive")
    if len(values) < 30:
        return None

    mean = statistics.mean(values)
    sample_sd = statistics.stdev(values)
    margin = 1.96 * sample_sd / math.sqrt(len(values))
    target_samples = max(
        30,
        math.ceil((1.96 * sample_sd / target_precision_s) ** 2),
    )
    return {
        "n": len(values),
        "mean": mean,
        "sample_sd": sample_sd,
        "margin": margin,
        "low": mean - margin,
        "high": mean + margin,
        "target_precision_s": target_precision_s,
        "target_samples": target_samples,
    }


def path_latency_stats(sent_messages, receipt_at, receipt_windows=None):
    """Summarize host-monotonic send-to-UI-observation latency per direction."""
    receipt_windows = receipt_windows or {}
    sent_by_tag = {message["tag"]: message for message in sent_messages}
    samples = {}
    for (sender, receiver, tag), observed_at in receipt_at.items():
        message = sent_by_tag.get(tag)
        if message is None or message["sender_device"] != sender or sender == receiver:
            continue
        latency = observed_at - message["sent_at"]
        if latency >= 0:
            samples.setdefault((sender, receiver), []).append(latency)

    result = []
    for (sender, receiver), values in sorted(samples.items()):
        values.sort()
        confidence = mean_latency_confidence(values)
        widths = [
            max(0.0, window["upper"] - window["lower"])
            for key, window in receipt_windows.items()
            if key[0] == sender and key[1] == receiver
        ]
        result.append(
            {
                "sender": sender,
                "receiver": receiver,
                "n": len(values),
                "mean": statistics.mean(values),
                "sample_sd": statistics.stdev(values) if len(values) >= 2 else None,
                "mean_95ci_margin": confidence["margin"] if confidence else None,
                "p50": _percentile(values, 0.50),
                "p95": _percentile(values, 0.95),
                "max": max(values),
                "mean_observation_window_s": (
                    statistics.mean(widths) if widths else None
                ),
                "max_observation_window_s": max(widths) if widths else None,
            }
        )
    return result


def latency_stage_stats(sent_messages, completed_at, receipt_windows):
    """Separate local send API time from propagation and bound UI polling error."""
    api_submit = []
    accepted_to_ui = []
    lower_bounds = []
    upper_bounds = []
    observation_widths = []
    for message in sent_messages:
        accepted_at = message.get("send_api_completed_at")
        if accepted_at is not None:
            api_duration = accepted_at - message["sent_at"]
            if api_duration >= 0:
                api_submit.append(api_duration)
        tag = message["tag"]
        if accepted_at is None or tag not in completed_at:
            continue
        accepted_to_ui.append(completed_at[tag] - accepted_at)
        path_windows = [
            window
            for (sender, _receiver, window_tag), window in receipt_windows.items()
            if sender == message["sender_device"] and window_tag == tag
        ]
        if not path_windows:
            continue
        lower = max(window["lower"] for window in path_windows)
        upper = completed_at[tag]
        lower_bounds.append(max(0.0, lower - message["sent_at"]))
        upper_bounds.append(max(0.0, upper - message["sent_at"]))
        observation_widths.append(max(0.0, upper - lower))

    def describe(values):
        if not values:
            return None
        ordered = sorted(values)
        return {
            "n": len(ordered),
            "mean": statistics.mean(ordered),
            "p50": _percentile(ordered, 0.50),
            "p95": _percentile(ordered, 0.95),
            "max": max(ordered),
        }

    return {
        "send_api_submit_s": describe(api_submit),
        "api_accept_to_all_receivers_ui_s": describe(accepted_to_ui),
        "end_to_end_lower_bound_s": describe(lower_bounds),
        "end_to_end_upper_bound_s": describe(upper_bounds),
        "end_to_end_observation_window_width_s": describe(observation_widths),
    }


def _mtu_attempt_summary(events):
    """Classify each request by the callback or terminal event in its trace."""
    terminal_names = {"client_attempt_failed", "client_disconnected"}
    relevant_names = terminal_names | {
        "client_mtu_requested",
        "client_mtu_ready",
        "client_mtu_failed",
        "client_mtu_fallback",
        "client_mtu_skipped",
    }
    attempts = {}
    for event in events:
        name = event.get("event", "").lower()
        attempt_id = event.get("attempt_id")
        if not attempt_id or name not in relevant_names:
            continue
        key = (event.get("device", ""), attempt_id, event.get("target_mac", ""))
        record = attempts.setdefault(
            key,
            {
                "device": key[0],
                "attempt_id": attempt_id,
                "target_mac": key[2],
                "events": [],
            },
        )
        record["events"].append(event)

    outcome_counts = {}
    grouped = {}
    reported_timeout_events = 0
    attempts_with_timeout_event = 0
    attempt_rows = []
    for record in attempts.values():
        request = next(
            (event for event in record["events"] if event.get("event", "").lower() == "client_mtu_requested"),
            None,
        )
        skipped = next(
            (event for event in record["events"] if event.get("event", "").lower() == "client_mtu_skipped"),
            None,
        )
        if request is None and skipped is None:
            continue
        rows = record["events"]
        ready = next(
            (event for event in rows if event.get("event", "").lower() == "client_mtu_ready"),
            None,
        )
        callback_failed = next(
            (event for event in rows if event.get("event", "").lower() == "client_mtu_failed"),
            None,
        )
        fallback = next(
            (event for event in rows if event.get("event", "").lower() == "client_mtu_fallback"),
            None,
        )
        disconnections = [
            event for event in rows
            if event.get("event", "").lower() == "client_disconnected"
            and (event.get("fields") or {}).get("phase", "").lower() == "request_mtu"
        ]
        failures = [
            event for event in rows
            if event.get("event", "").lower() == "client_attempt_failed"
            and (event.get("fields") or {}).get("phase", "").lower() == "request_mtu"
        ]
        if ready:
            outcome = "ready_callback"
        elif fallback:
            outcome = "default_mtu_fallback"
        elif skipped:
            outcome = "negotiation_skipped"
        elif callback_failed:
            outcome = "failed_callback"
        elif disconnections:
            outcome = "disconnected_before_callback"
        elif failures:
            outcome = "failed_before_callback"
        else:
            outcome = "pending_at_capture_end"

        starts = (request.get("fields") or {}).get("started", "").lower() if request else ""
        request_started = True if starts == "true" else False if starts == "false" else None
        timeout_rows = [
            event for event in failures
            if (event.get("fields") or {}).get("error_code", "").lower() == "transfer_timeout"
        ]
        reported_timeout_events += len(timeout_rows)
        if timeout_rows:
            attempts_with_timeout_event += 1
        failure_codes = sorted(
            {
                (event.get("fields") or {}).get("error_code", "unknown")
                for event in failures
            }
        )
        if disconnections:
            failure_codes.extend(
                "disconnect_status_" + str((event.get("fields") or {}).get("status", "unknown"))
                for event in disconnections
            )
        request_time = request.get("host_observed_at") if request else None
        request_phone_time = request.get("mono_ms") if request else None
        terminal_events = disconnections + failures
        terminal_time = min(
            (
                event.get("host_observed_at")
                for event in terminal_events
                if event.get("host_observed_at") is not None
            ),
            default=None,
        )
        row = {
            "device": record["device"],
            "attempt_id": record["attempt_id"],
            "target_mac": record["target_mac"],
            "outcome": outcome,
            "request_started": request_started,
            "requested_mtu": (request.get("fields") or {}).get("requested_mtu") if request else None,
            "callback_mtu": (
                (ready or callback_failed or {}).get("fields", {}).get("mtu")
            ),
            "callback_status": (
                (ready or callback_failed or {}).get("fields", {}).get("status")
            ),
            "fallback_reason": (fallback.get("fields") or {}).get("reason") if fallback else None,
            "fallback_wait_ms": (fallback.get("fields") or {}).get("wait_ms") if fallback else None,
            "skipped_reason": (skipped.get("fields") or {}).get("reason") if skipped else None,
            "request_observed_at_host_monotonic_s": request_time,
            "request_phone_local_mono_ms": request_phone_time,
            "terminal_observed_at_host_monotonic_s": terminal_time,
            "terminal_phone_local_mono_ms": min(
                (
                    event.get("mono_ms")
                    for event in terminal_events
                    if event.get("mono_ms") is not None
                ),
                default=None,
            ),
            "reported_failure_codes": sorted(set(failure_codes)),
        }
        attempt_rows.append(row)
        outcome_counts[outcome] = outcome_counts.get(outcome, 0) + 1
        group_key = (record["device"], record["target_mac"])
        group = grouped.setdefault(
            group_key,
            {
                "device": record["device"],
                "target_mac": record["target_mac"],
                "requests": 0,
                "request_started_true": 0,
                "request_started_false": 0,
                "request_started_unknown": 0,
                "ready_callbacks": 0,
                "failed_callbacks": 0,
                "fallbacks": 0,
                "skipped": 0,
                "disconnected_before_callback": 0,
                "failed_before_callback": 0,
                "pending_at_capture_end": 0,
            },
        )
        if request is not None:
            group["requests"] += 1
            group["request_started_" + ("true" if request_started is True else "false" if request_started is False else "unknown")] += 1
        if outcome == "ready_callback":
            group["ready_callbacks"] += 1
        elif outcome == "default_mtu_fallback":
            group["fallbacks"] += 1
        elif outcome == "negotiation_skipped":
            group["skipped"] += 1
        elif outcome == "failed_callback":
            group["failed_callbacks"] += 1
        elif outcome == "disconnected_before_callback":
            group["disconnected_before_callback"] += 1
        elif outcome == "failed_before_callback":
            group["failed_before_callback"] += 1
        else:
            group["pending_at_capture_end"] += 1

    return {
        "requests": sum(row["requested_mtu"] is not None for row in attempt_rows),
        "request_started_true": sum(row["request_started"] is True for row in attempt_rows),
        "request_started_false": sum(row["request_started"] is False for row in attempt_rows),
        "ready_callbacks": outcome_counts.get("ready_callback", 0),
        "failed_callbacks": outcome_counts.get("failed_callback", 0),
        "fallbacks": outcome_counts.get("default_mtu_fallback", 0),
        "skipped": outcome_counts.get("negotiation_skipped", 0),
        "disconnected_before_callback": outcome_counts.get("disconnected_before_callback", 0),
        "failed_before_callback": outcome_counts.get("failed_before_callback", 0),
        "pending_at_capture_end": outcome_counts.get("pending_at_capture_end", 0),
        "reported_transfer_timeout_events": reported_timeout_events,
        "attempts_with_transfer_timeout_event": attempts_with_timeout_event,
        "by_device_peer": [grouped[key] for key in sorted(grouped)],
        "attempts": sorted(attempt_rows, key=lambda row: (row["device"], row["attempt_id"])),
    }


def _connection_pressure_summary(events, mtu_attempts):
    """Retain admission events and correlate callback stalls with live inbound links."""
    relevant_names = {
        "client_connect_started",
        "client_connected",
        "client_disconnected",
        "client_attempt_failed",
        "server_connected",
        "server_disconnected",
        "server_connection_rejected",
        "server_pending_eviction_requested",
    }
    activity = []
    latest_by_device = {}
    inbound_starts = {}
    inbound_intervals = []
    connect_attempts = {}
    connect_failures_by_error = {}
    disconnect_by_connection = {}
    connect_starts = []
    rejects_by_reason = {}
    rejects_by_active_count = {}
    outbound_attempt_keys = set()
    for event in events:
        name = event.get("event", "").lower()
        host_time = event.get("host_observed_at")
        phone_time = event.get("mono_ms")
        device = event.get("device", "")
        fields = event.get("fields") or {}
        if phone_time is not None:
            latest_by_device[device] = max(
                latest_by_device.get(device, phone_time), phone_time
            )
        if name not in relevant_names:
            continue
        row = {
            "device": device,
            "event": name,
            "host_observed_at_monotonic_s": host_time,
            "phone_local_mono_ms": phone_time,
            "attempt_id": event.get("attempt_id"),
            "connection_id": event.get("connection_id"),
            "target_mac": event.get("target_mac"),
        }
        for key in ("phase", "status", "reason", "error_code", "active"):
            if key in fields:
                row[key] = fields[key]
        activity.append(row)

        if name == "client_connect_started" and phone_time is not None:
            attempt_id = event.get("attempt_id")
            key = (device, attempt_id)
            outbound_attempt_keys.add(key)
            connect_starts.append((device, attempt_id, phone_time))
            connect_attempts.setdefault(
                key,
                {
                    "device": device,
                    "attempt_id": attempt_id,
                    "target_mac": event.get("target_mac"),
                    "start": phone_time,
                    "end": None,
                    "outcome": "pending",
                    "error_code": None,
                },
            )
        elif name == "client_connected" and phone_time is not None:
            attempt = connect_attempts.get((device, event.get("attempt_id")))
            if attempt is not None and attempt["end"] is None:
                attempt["end"] = phone_time
                attempt["outcome"] = "connected"
        elif name == "client_attempt_failed" and phone_time is not None:
            phase = str(fields.get("phase", "")).lower()
            error_code = str(fields.get("error_code", "unknown"))
            if phase == "connecting":
                connect_failures_by_error[error_code] = (
                    connect_failures_by_error.get(error_code, 0) + 1
                )
                attempt = connect_attempts.get((device, event.get("attempt_id")))
                if attempt is not None and attempt["end"] is None:
                    attempt["end"] = phone_time
                    attempt["outcome"] = "failed_before_connected"
                    attempt["error_code"] = error_code
        elif name == "client_disconnected" and phone_time is not None:
            attempt = connect_attempts.get((device, event.get("attempt_id")))
            if attempt is not None and attempt["end"] is None:
                attempt["end"] = phone_time
                attempt["outcome"] = "disconnected_before_connected"
        elif name == "server_connected" and phone_time is not None:
            key = (device, event.get("connection_id", ""))
            inbound_starts[key] = phone_time
        elif name == "server_disconnected" and phone_time is not None:
            key = (device, event.get("connection_id", ""))
            disconnect_by_connection[key] = phone_time
        elif name == "server_connection_rejected":
            reason = fields.get("reason", "unknown")
            rejects_by_reason[reason] = rejects_by_reason.get(reason, 0) + 1
            active = fields.get("active", "unknown")
            rejects_by_active_count[active] = rejects_by_active_count.get(active, 0) + 1

    for key, start in inbound_starts.items():
        device, _ = key
        end = disconnect_by_connection.get(key, latest_by_device.get(device, start))
        if end >= start:
            inbound_intervals.append((device, start, end, key in disconnect_by_connection))

    connect_attempt_rows = []
    for attempt in connect_attempts.values():
        start = attempt["start"]
        end = attempt["end"]
        if end is None:
            end = latest_by_device.get(attempt["device"], start)
        if end < start:
            continue
        device = attempt["device"]
        inbound_overlap = any(
            inbound_device == device
            and interval_start <= end
            and interval_end >= start
            for inbound_device, interval_start, interval_end, _ in inbound_intervals
        )
        outbound_overlap = any(
            other["device"] == device
            and other["attempt_id"] != attempt["attempt_id"]
            and other["start"] <= end
            and (
                other["end"]
                if other["end"] is not None
                else latest_by_device.get(device, other["start"])
            ) >= start
            for other in connect_attempts.values()
        )
        connect_attempt_rows.append(
            {
                "device": device,
                "attempt_id": attempt["attempt_id"],
                "target_mac": attempt["target_mac"],
                "start_phone_local_mono_ms": start,
                "end_phone_local_mono_ms": end,
                "duration_ms": end - start,
                "outcome": attempt["outcome"],
                "error_code": attempt["error_code"],
                "overlapped_inbound_link": inbound_overlap,
                "overlapped_another_outbound_connect": outbound_overlap,
            }
        )
    failed_connect_rows = [
        row for row in connect_attempt_rows
        if row["outcome"] == "failed_before_connected"
    ]

    no_callback_rows = [
        row for row in mtu_attempts["attempts"]
        if row["outcome"] in {
            "disconnected_before_callback",
            "failed_before_callback",
            "pending_at_capture_end",
        }
    ]
    inbound_overlaps = 0
    closed_inbound_overlaps = 0
    outbound_starts_during_wait = 0
    for attempt in no_callback_rows:
        start = attempt.get("request_phone_local_mono_ms")
        device = attempt["device"]
        end = attempt.get("terminal_phone_local_mono_ms")
        if end is None:
            end = latest_by_device.get(device, start)
        if start is None or end is None:
            continue
        any_overlap = any(
            inbound_device == device and interval_start <= end and interval_end >= start
            for inbound_device, interval_start, interval_end, _ in inbound_intervals
        )
        if any_overlap:
            inbound_overlaps += 1
        if any(
            inbound_device == device
            and was_closed
            and interval_start <= end
            and interval_end >= start
            for inbound_device, interval_start, interval_end, was_closed in inbound_intervals
        ):
            closed_inbound_overlaps += 1
        if any(
            other_device == device
            and other_attempt_id != attempt["attempt_id"]
            and start <= connect_time <= end
            for other_device, other_attempt_id, connect_time in connect_starts
        ):
            outbound_starts_during_wait += 1

    return {
        "outbound_connect_attempts": len(outbound_attempt_keys),
        "connect_phase_failures_by_error": connect_failures_by_error,
        "connect_attempts_overlapping_inbound_link": sum(
            row["overlapped_inbound_link"] for row in connect_attempt_rows
        ),
        "connect_attempts_overlapping_another_outbound_connect": sum(
            row["overlapped_another_outbound_connect"]
            for row in connect_attempt_rows
        ),
        "failed_connect_attempts_overlapping_inbound_link": sum(
            row["overlapped_inbound_link"] for row in failed_connect_rows
        ),
        "failed_connect_attempts_overlapping_another_outbound_connect": sum(
            row["overlapped_another_outbound_connect"]
            for row in failed_connect_rows
        ),
        "connect_attempt_activity": connect_attempt_rows,
        "inbound_connections_accepted": len(inbound_starts),
        "inbound_rejections_by_reason": rejects_by_reason,
        "inbound_rejections_by_active_count": rejects_by_active_count,
        "inbound_sessions_unclosed_at_capture_end": sum(
            not was_closed for _, _, _, was_closed in inbound_intervals
        ),
        "pending_slot_eviction_requests": sum(
            event.get("event", "").lower() == "server_pending_eviction_requested"
            for event in events
        ),
        "no_callback_attempts_overlapping_inbound_link_including_open": inbound_overlaps,
        "no_callback_attempts_overlapping_closed_inbound_link": closed_inbound_overlaps,
        "no_callback_attempts_with_other_outbound_connect_start": outbound_starts_during_wait,
        "activity": activity,
    }


def ble_trace_summary(events, android_bluetooth_logs=()):
    """Summarize native GATT phases using each phone's monotonic clock."""
    phase_edges = {
        "connect": ("client_connect_started", "client_connected"),
        "mtu": ("client_connected", "client_mtu_ready"),
        "service_discovery": (
            "client_discovery_started",
            "client_services_ready",
        ),
        "notification_subscription": (
            "client_cccd_write_started",
            "client_cccd_ready",
        ),
        "offer_to_delta_eof": (
            "client_offer_eof_sent",
            "client_delta_eof_received",
        ),
        "held_link_reuse": (
            "client_held_link_reuse",
            "client_held_link_complete",
        ),
    }
    attempts = {}
    errors = {}
    failures_by_phase_error = {}
    notify_waits = []
    notify_callbacks = 0
    notify_rejections = 0
    server_rejections = {}
    server_pending_eviction_requests = 0
    held_link_failures = 0
    rssi_by_peer = {}
    urgent_dial_selections = []

    for event in events:
        name = event.get("event", "").lower()
        fields = event.get("fields") or {}
        mono_ms = event.get("mono_ms")
        attempt_id = event.get("attempt_id")
        if attempt_id and mono_ms is not None:
            attempts.setdefault((event.get("device"), attempt_id), {})[name] = mono_ms
        if name == "client_attempt_failed":
            reason = fields.get("error_code", "unknown")
            errors[reason] = errors.get(reason, 0) + 1
            phase = fields.get("phase", "unknown")
            phase_errors = failures_by_phase_error.setdefault(phase, {})
            phase_errors[reason] = phase_errors.get(reason, 0) + 1
        elif name == "client_held_link_failed":
            held_link_failures += 1
        if name == "server_connection_rejected":
            reason = fields.get("reason", "unknown")
            server_rejections[reason] = server_rejections.get(reason, 0) + 1
        elif name == "server_pending_eviction_requested":
            server_pending_eviction_requests += 1
        elif name == "urgent_dial_selection":
            def optional_int(field):
                try:
                    return int(fields[field])
                except (KeyError, TypeError, ValueError):
                    return None

            def optional_bool(field):
                value = fields.get(field)
                if value is None:
                    return None
                return str(value).lower() == "true"

            urgent_dial_selections.append(
                {
                    "device": event.get("device", ""),
                    "peer_node_id": fields.get("peer_node_id"),
                    "target_mac": event.get("target_mac"),
                    "target_sources": fields.get("target_sources"),
                    "candidate_macs": fields.get("candidates"),
                    "last_scan_mac": fields.get("last_scan_mac"),
                    "last_scan_age_ms": optional_int("last_scan_age_ms"),
                    "fresh_scan_allowed": optional_bool("fresh_scan_allowed"),
                    "current_neighbor": optional_bool("current_neighbor"),
                    "dead_remaining_ms": optional_int("dead_remaining_ms"),
                    "wall_ms": optional_int("wall_ms"),
                }
            )
        if name == "server_notify_complete":
            try:
                notify_waits.append(float(fields.get("wait_ms", "")))
            except (TypeError, ValueError):
                pass
            if fields.get("callback", "").lower() not in ("", "null"):
                notify_callbacks += 1
        elif name == "server_notify_rejected":
            notify_rejections += 1
        if name == "scan_seen" and event.get("rssi") is not None:
            key = (event.get("device"), event.get("target_mac", ""))
            rssi_by_peer.setdefault(key, []).append(event["rssi"])

    phase_samples = {name: [] for name in phase_edges}
    attempt_count = len(attempts)
    for phases in attempts.values():
        for name, (start_event, end_event) in phase_edges.items():
            start = phases.get(start_event)
            end = phases.get(end_event)
            if start is not None and end is not None and end >= start:
                phase_samples[name].append(float(end - start))

    phase_stats = {}
    for name, values in phase_samples.items():
        if not values:
            continue
        values.sort()
        phase_stats[name] = {
            "n": len(values),
            "mean_ms": statistics.mean(values),
            "p50_ms": _percentile(values, 0.50),
            "p95_ms": _percentile(values, 0.95),
            "max_ms": max(values),
        }

    rssi_stats = []
    for (device, mac), values in sorted(rssi_by_peer.items()):
        rssi_stats.append(
            {
                "device": device,
                "mac": mac,
                "n": len(values),
                "mean_dbm": statistics.mean(values),
                "min_dbm": min(values),
                "max_dbm": max(values),
            }
        )

    mtu_negotiation = _mtu_attempt_summary(events)
    stack_log_counts = {}
    for event in android_bluetooth_logs:
        key = (event.get("device", ""), event.get("tag", ""), event.get("priority", ""))
        stack_log_counts[key] = stack_log_counts.get(key, 0) + 1
    return {
        "clock": "phone-local-elapsedRealtime",
        "event_count": len(events),
        "client_attempt_count": attempt_count,
        "client_failures_by_error": errors,
        "client_failures_by_phase_and_error": failures_by_phase_error,
        "client_mtu_negotiation": mtu_negotiation,
        "connection_pressure": _connection_pressure_summary(events, mtu_negotiation),
        "android_stack_logs": {
            "count": len(android_bluetooth_logs),
            "counts_by_device_tag_priority": [
                {
                    "device": key[0],
                    "tag": key[1],
                    "priority": key[2],
                    "count": stack_log_counts[key],
                }
                for key in sorted(stack_log_counts)
            ],
            "events": list(android_bluetooth_logs),
        },
        "held_link_failures": held_link_failures,
        "server_rejections_by_reason": server_rejections,
        "server_pending_eviction_requests": server_pending_eviction_requests,
        "client_phase_ms": phase_stats,
        "urgent_dial_selections": urgent_dial_selections,
        "server_notify": {
            "n": len(notify_waits),
            "mean_wait_ms": statistics.mean(notify_waits) if notify_waits else None,
            "p95_wait_ms": _percentile(sorted(notify_waits), 0.95) if notify_waits else None,
            "callback_count": notify_callbacks,
            "fallback_count": len(notify_waits) - notify_callbacks,
            "immediate_rejection_count": notify_rejections,
        },
        "scan_rssi": rssi_stats,
    }


def summarize_run(result):
    """Return JSON-friendly overall and directed-path metrics for one run."""
    sent = result["sent_messages"]
    completed = result["completed_at"]
    values = sorted(
        completed[item["tag"]] - item["sent_at"]
        for item in sent
        if item["tag"] in completed
    )
    status = result["status"]
    elapsed = max(status.get("elapsed_s", 0.0), 0.001)
    confidence = mean_latency_confidence(values) if len(values) == len(sent) else None
    poll_interval_s = result.get("poll_interval_s", 2.0)
    delivered = status.get("propagated", 0)
    return {
        "success": result["success"],
        "profile": result.get("profile", "burst"),
        "send_interval_s": result.get("send_interval_s", 0.3),
        "sender_port": result.get("sender_port"),
        "messages_sent": len(sent),
        "messages_delivered": delivered,
        "delivery_ratio": delivered / len(sent) if sent else 0.0,
        "elapsed_s": elapsed,
        "throughput_msg_s": status.get("propagated", 0) / elapsed,
        "latency": (
            {
                "n": len(values),
                "mean": statistics.mean(values),
                "p50": _percentile(values, 0.50),
                "p95": _percentile(values, 0.95),
                "max": max(values),
                "sample_sd": statistics.stdev(values) if len(values) >= 2 else None,
                "mean_95ci_margin": confidence["margin"] if confidence else None,
                "mean_95ci": (
                    {"low": confidence["low"], "high": confidence["high"]}
                    if confidence
                    else None
                ),
            }
            if values
            else None
        ),
        "paths": path_latency_stats(
            sent,
            result.get("receipt_at", {}),
            result.get("receipt_windows", {}),
        ),
        "latency_stages": latency_stage_stats(
            sent,
            completed,
            result.get("receipt_windows", {}),
        ),
        "preflight": result.get("preflight", {}),
        "device_metadata": result.get("device_metadata", []),
        "latency_measurement": {
            "clock": "host-monotonic",
            "receipt_event": "first /ui observation",
            "poll_interval_s": poll_interval_s,
            "receipt_interval": "between last successful absent poll and first present poll",
            "confidence_method": "normal approximation for the mean; assumes independent samples",
        },
        "device_runtime_state": result.get("device_runtime_state", {}),
        "peer_signal_samples": result.get("peer_signal_samples", []),
        "bluetooth_socket_captures": result.get("bluetooth_socket_captures", []),
        "bluetooth_diagnostics": result.get("bluetooth_diagnostics"),
        "ble_diagnostics": ble_trace_summary(
            result.get("ble_trace_events", []),
            result.get("android_bluetooth_logs", []),
        ),
        "connection_failures": result["connection_failures"],
        "connection_rejections": result.get("connection_rejections", 0),
        "penalty_entries": result["penalty_entries"],
        "send_failures": result.get(
            "send_failures",
            sum(not message.get("send_ok", True) for message in sent),
        ),
    }


def print_run_summary(stream, result, details_path):
    sent = result["sent_messages"]
    completed = result["completed_at"]
    status = result["status"]
    latencies = [
        (
            completed[item["tag"]] - item["sent_at"],
            item,
            completed[item["tag"]],
        )
        for item in sent
        if item["tag"] in completed
    ]
    latencies.sort(key=lambda entry: entry[0])
    values = [entry[0] for entry in latencies]
    summary = summarize_run(result)
    elapsed = max(status.get("elapsed_s", 0.0), 0.001)
    propagated = status.get("propagated", 0)
    message_rate = propagated / elapsed
    data_rate = format_data_rate(
        status.get("transferred_bytes", 0) / elapsed
    )

    stream.write("\nOverall\n")
    stream.write(
        f"  Messages: {propagated}/{len(sent)} in {elapsed:.2f}s\n"
        f"  Throughput: {message_rate:.2f} msg/s | {data_rate}\n"
    )
    for device in summary["device_metadata"]:
        model = device.get("model", "unknown model")
        sdk = device.get("android_sdk", "unknown SDK")
        stream.write(
            f"  Device: {model} (Android SDK {sdk}) serial={device.get('serial', '?')}\n"
        )

    runtime = summary["device_runtime_state"]
    start_states = {
        state.get("serial"): state
        for state in runtime.get("start", {}).get("devices", [])
    }
    end_states = {
        state.get("serial"): state
        for state in runtime.get("end", {}).get("devices", [])
    }
    if start_states or end_states:
        stream.write("\nDevice runtime state (ADB snapshots)\n")
        for serial in sorted(set(start_states) | set(end_states)):
            start_state = start_states.get(serial, {})
            end_state = end_states.get(serial, {})
            stream.write(
                f"  {serial}: start locked={start_state.get('device_locked', 'unknown')} "
                f"wakefulness={start_state.get('wakefulness', 'unknown')} "
                f"display={start_state.get('display_power_state', 'unknown')}; "
                f"end locked={end_state.get('device_locked', 'unknown')} "
                f"wakefulness={end_state.get('wakefulness', 'unknown')} "
                f"display={end_state.get('display_power_state', 'unknown')}\n"
            )
        samples = runtime.get("samples", [])
        stream.write(
            f"  Mid-run state samples: {len(samples)} every "
            f"{runtime.get('sample_interval_s', 'unknown')}s; "
            "sample and GATT log timestamps share the host monotonic clock.\n"
        )

    bluetooth_diagnostics = summary.get("bluetooth_diagnostics")
    if bluetooth_diagnostics is not None:
        stream.write("\nBluetooth HCI diagnostics\n")
        for device in summary.get("preflight", {}).get("bluetooth_hci_snoop", []):
            stream.write(
                f"  {device['serial']}: full snoop="
                f"{device.get('full_hci_snoop_enabled')} root={device.get('root_access')}\n"
            )
        for capture in bluetooth_diagnostics:
            stream.write(
                f"  {capture['serial']}: {len(capture['artifacts'])} artifact(s), "
                f"{len(capture['errors'])} capture error(s)\n"
            )
            for artifact in capture["artifacts"]:
                stream.write(
                    f"    {artifact['scope']}: {artifact['packets']} packets "
                    f"({artifact['bytes']} bytes) — {artifact['path']}\n"
                )
            for error in capture["errors"]:
                stream.write(f"    capture error: {error}\n")
        for capture in summary.get("bluetooth_socket_captures", []):
            stream.write(
                f"  {capture['serial']}: live socket packets={capture.get('packets')} "
                f"bytes={capture.get('bytes')} path={capture.get('path')} "
                f"error={capture.get('error')}\n"
            )
    ble = summary["ble_diagnostics"]
    mtu = ble["client_mtu_negotiation"]
    if mtu["requests"] or ble["event_count"]:
        stream.write("\nGATT MTU callback outcomes\n")
        stream.write(
            f"  requests={mtu['requests']} started=true={mtu['request_started_true']} "
            f"started=false={mtu['request_started_false']} "
            f"ready_callbacks={mtu['ready_callbacks']} "
            f"failed_callbacks={mtu['failed_callbacks']} "
            f"default_mtu_fallbacks={mtu['fallbacks']} "
            f"debug_skipped={mtu['skipped']} "
            f"disconnected_before_callback={mtu['disconnected_before_callback']} "
            f"failed_before_callback={mtu['failed_before_callback']} "
            f"pending_at_capture_end={mtu['pending_at_capture_end']}\n"
        )
        if mtu["reported_transfer_timeout_events"]:
            stream.write(
                f"  transfer_timeout log events matched to request IDs="
                f"{mtu['reported_transfer_timeout_events']} across "
                f"{mtu['attempts_with_transfer_timeout_event']} MTU attempts; "
                "timeout and disconnect events can describe the same attempt.\n"
            )
        request_phase_failures = ble["client_failures_by_phase_and_error"].get(
            "request_mtu", {}
        )
        if request_phase_failures:
            stream.write(
                "  all request_mtu failure events: "
                + ", ".join(
                    f"{error}={count}"
                    for error, count in sorted(request_phase_failures.items())
                )
                + "\n"
            )
        pressure = ble["connection_pressure"]
        stream.write(
            f"  connection pressure: outbound starts={pressure['outbound_connect_attempts']} "
            f"connect-phase failures={pressure['connect_phase_failures_by_error']} "
            f"inbound accepted={pressure['inbound_connections_accepted']} "
            f"rejections={pressure['inbound_rejections_by_reason']} "
            f"pending-slot evictions={pressure['pending_slot_eviction_requests']}\n"
            f"  failed connect attempts overlapping an inbound link="
            f"{pressure['failed_connect_attempts_overlapping_inbound_link']}; "
            f"overlapping another outbound connect="
            f"{pressure['failed_connect_attempts_overlapping_another_outbound_connect']}\n"
            f"  no-callback attempts overlapping a closed inbound link="
            f"{pressure['no_callback_attempts_overlapping_closed_inbound_link']} "
            f"({pressure['no_callback_attempts_overlapping_inbound_link_including_open']} "
            f"including links still open at capture); "
            f"overlapping another outbound connect start="
            f"{pressure['no_callback_attempts_with_other_outbound_connect_start']}\n"
        )
        stack_logs = ble["android_stack_logs"]
        warning_or_error_logs = sum(
            item["count"]
            for item in stack_logs["counts_by_device_tag_priority"]
            if item["priority"] in {"W", "E", "F"}
        )
        stream.write(
            f"  Android Bluetooth framework/stack log lines="
            f"{stack_logs['count']} (warning/error/fatal={warning_or_error_logs}); "
            "all captured lines are in the JSON summary; warnings and errors are "
            "plus MTU/GATT failure lines are copied to the details log.\n"
        )
    if result.get("profile") == "interactive":
        stream.write("  Profile: interactive (waited for all peer UIs per message)\n")
    else:
        offered_rate = (
            1.0 / result["send_interval_s"]
            if result.get("send_interval_s", 0) > 0
            else None
        )
        if offered_rate is not None:
            stream.write(
                f"  Profile: burst (nominal spacing "
                f"{result['send_interval_s']:.3f}s, offered rate "
                f"{offered_rate:.2f} msg/s before API overhead)\n"
            )
    if values:
        mean = statistics.mean(values)
        p50 = _percentile(values, 0.50)
        p95 = _percentile(values, 0.95)
        stream.write(
            f"  Latency: avg {mean:.2f}s | p50 {p50:.2f}s | "
            f"p95 {p95:.2f}s | max {max(values):.2f}s\n"
        )

        paths = summary["paths"]
        if paths:
            stream.write("\nPer-direction UI-observed latency\n")
            for path in paths:
                stream.write(
                    f"  {path['sender'][-6:]}→{path['receiver'][-6:]}: "
                    f"n={path['n']} mean={path['mean']:.2f}s "
                    f"p50={path['p50']:.2f}s p95={path['p95']:.2f}s "
                    f"max={path['max']:.2f}s\n"
                )

        stream.write(
            "\nEnd-to-end timing: host monotonic clock, first /ui observation; "
            f"poll interval {result.get('poll_interval_s', 2.0):g}s.\n"
        )
        stages = summary["latency_stages"]
        api_stage = stages["send_api_submit_s"]
        propagation_stage = stages["api_accept_to_all_receivers_ui_s"]
        observation_stage = stages["end_to_end_observation_window_width_s"]
        if api_stage or propagation_stage:
            stream.write("  Host-monotonic stage split")
            if api_stage:
                stream.write(
                    f" | /send API mean={api_stage['mean']:.3f}s"
                )
            if propagation_stage:
                stream.write(
                    f" | API acceptance→all UIs mean="
                    f"{propagation_stage['mean']:.3f}s"
                )
            if observation_stage:
                stream.write(
                    f" | polling window mean/max="
                    f"{observation_stage['mean']:.3f}/"
                    f"{observation_stage['max']:.3f}s"
                )
            stream.write("\n")

        if (
            ble["client_phase_ms"]
            or ble["server_notify"]["n"]
            or ble["server_rejections_by_reason"]
            or ble["server_pending_eviction_requests"]
        ):
            stream.write(
                "\nNative BLE stage timing (phone-local monotonic clocks)\n"
            )
            for phase, stats in ble["client_phase_ms"].items():
                stream.write(
                    f"  {phase}: n={stats['n']} mean={stats['mean_ms']:.1f}ms "
                    f"p50={stats['p50_ms']:.1f}ms p95={stats['p95_ms']:.1f}ms\n"
                )
            notify = ble["server_notify"]
            if notify["n"]:
                stream.write(
                    f"  notify wait: n={notify['n']} "
                    f"mean={notify['mean_wait_ms']:.1f}ms "
                    f"p95={notify['p95_wait_ms']:.1f}ms "
                    f"callbacks={notify['callback_count']} "
                    f"fallbacks={notify['fallback_count']} "
                    f"rejected={notify['immediate_rejection_count']}\n"
                )
            if ble["client_failures_by_error"]:
                stream.write(
                    "  failures by stage: "
                    + ", ".join(
                        f"{reason}={count}"
                        for reason, count in sorted(
                            ble["client_failures_by_error"].items()
                        )
                    )
                    + "\n"
                )
            if ble["held_link_failures"]:
                stream.write(f"  held-link failures: {ble['held_link_failures']}\n")
            if (
                ble["server_rejections_by_reason"]
                or ble["server_pending_eviction_requests"]
            ):
                stream.write(
                    f"  inbound admission: rejections="
                    f"{ble['server_rejections_by_reason']} pending_evictions="
                    f"{ble['server_pending_eviction_requests']} requested\n"
                )
        if ble["scan_rssi"]:
            stream.write("\nSampled BLE RSSI by scanner and address\n")
            for sample in ble["scan_rssi"]:
                stream.write(
                    f"  {sample['device'][-6:]}→{sample['mac'][-6:]}: "
                    f"n={sample['n']} mean={sample['mean_dbm']:.1f}dBm "
                    f"range={sample['min_dbm']}..{sample['max_dbm']}dBm\n"
                )

        if len(values) == len(sent):
            confidence = mean_latency_confidence(values)
            if confidence is not None:
                confidence_text = (
                    "  Mean latency 95% CI (normal approximation): "
                    f"[{confidence['low']:.2f}, {confidence['high']:.2f}]s "
                    f"(n={confidence['n']}, margin ±{confidence['margin']:.2f}s)\n"
                    f"  At observed SD {confidence['sample_sd']:.2f}s, "
                    f"±0.01s would need about {confidence['target_samples']:,} "
                    "independent messages.\n"
                    f"  CI is for host-observed completion; "
                    f"{result.get('poll_interval_s', 2.0):g}s UI polling and "
                    "within-run BLE correlation limit its interpretation.\n"
                )
                stream.write(confidence_text)
                with open(details_path, "a", encoding="utf-8") as details:
                    details.write("\nHost-observed latency confidence\n")
                    details.write(confidence_text)
            else:
                stream.write("  Mean latency 95% CI: unavailable (need 30+ samples)\n")
        else:
            stream.write(
                "  Mean latency 95% CI: unavailable (some messages were "
                "unresolved)\n"
            )

        threshold = max(5.0, mean + 3 * statistics.pstdev(values))
        outliers = [entry for entry in latencies if entry[0] > threshold]
        if outliers:
            stream.write(
                f"\nOutliers ({len(outliers)} above {threshold:.2f}s)\n"
            )
            for latency, item, completed_time in sorted(
                outliers, key=lambda entry: entry[0], reverse=True
            )[:10]:
                sender = item["sender_device"][-6:]
                receivers = ",".join(
                    device[-6:]
                    for device in result["all_devices"]
                    if device != item["sender_device"]
                )
                if completed_time > result["sending_finished_at"]:
                    tail = completed_time - result["sending_finished_at"]
                    reason = f"recovered by tail catch-up (+{tail:.2f}s)"
                else:
                    reason = "caught up during the live burst"
                short_tag = item["tag"].split("@", 1)[0]
                stream.write(
                    f"  {short_tag} {sender}→{receivers}: "
                    f"{latency:.2f}s — {reason}\n"
                )
            if len(outliers) > 10:
                stream.write(f"  …and {len(outliers) - 10} more\n")
        else:
            stream.write("\nOutliers: none\n")

    stream.write(
        f"  Reliability: {result['connection_failures']} connection failures | "
        f"{result.get('connection_rejections', 0)} inbound rejections | "
        f"{result['penalty_entries']} penalty entries | "
        f"{summary['send_failures']} send failures\n"
    )
    unresolved = len(sent) - propagated
    if unresolved:
        stream.write(f"\nUnresolved at timeout: {unresolved}\n")
    stream.write(f"\nDetails: {details_path}\n")
    stream.flush()
    return summary


def _percentile(values, fraction):
    index = round((len(values) - 1) * fraction)
    return values[index]
