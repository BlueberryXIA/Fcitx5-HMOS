// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Haochen Xia
//
/*
 * NAPI bindings that expose the Rime engine to ArkTS.
 *
 * The module is deliberately a thin, synchronous façade: ArkTS owns the
 * keyboard, candidate UI and input-connection plumbing, and this layer owns
 * librime.  The one asynchronous piece is deployment, which runs on librime's
 * own maintenance thread and reports progress through a
 * napi_threadsafe_function.
 *
 * Session identifiers are opaque uintptr_t values inside librime (they are
 * literally object addresses).  They are surfaced as JavaScript numbers, which
 * represent every integer below 2^53 exactly -- comfortably wider than the
 * 48-bit user address space on OHOS -- so no precision is lost.
 */

#include <napi/native_api.h>

#include <hilog/log.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "rime_engine.h"

namespace {

constexpr char kLogTag[] = "RimeNapi";
constexpr unsigned int kLogDomain = 0x0000;

// ---------------------------------------------------------------------------
// error helpers
// ---------------------------------------------------------------------------

void LogError(const char* message) {
  OH_LOG_Print(LOG_APP, LOG_ERROR, kLogDomain, kLogTag, "%{public}s", message);
}

// Throws a JS TypeError with `message` and returns nullptr so callers can
// `return ThrowTypeError(...)`.
napi_value ThrowTypeError(napi_env env, const char* message) {
  LogError(message);
  napi_throw_type_error(env, nullptr, message);
  return nullptr;
}

napi_value ThrowError(napi_env env, const char* message) {
  LogError(message);
  napi_throw_error(env, nullptr, message);
  return nullptr;
}

// ---------------------------------------------------------------------------
// argument helpers
// ---------------------------------------------------------------------------

bool GetUint64(napi_env env, napi_value value, uint64_t* result) {
  int64_t as_int = 0;
  if (napi_get_value_int64(env, value, &as_int) != napi_ok) {
    return false;
  }
  *result = static_cast<uint64_t>(as_int);
  return true;
}

bool GetInt32(napi_env env, napi_value value, int32_t* result) {
  return napi_get_value_int32(env, value, result) == napi_ok;
}

bool GetBool(napi_env env, napi_value value, bool* result) {
  bool as_bool = false;
  if (napi_get_value_bool(env, value, &as_bool) != napi_ok) {
    return false;
  }
  *result = as_bool;
  return true;
}

bool GetString(napi_env env, napi_value value, std::string* result) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
    return false;
  }
  std::vector<char> buffer(length + 1, '\0');
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(),
                                 &length) != napi_ok) {
    return false;
  }
  result->assign(buffer.data(), length);
  return true;
}

napi_value MakeString(napi_env env, const std::string& value) {
  napi_value result = nullptr;
  napi_create_string_utf8(env, value.c_str(), value.size(), &result);
  return result;
}

napi_value MakeUint64(napi_env env, uint64_t value) {
  napi_value result = nullptr;
  napi_create_int64(env, static_cast<int64_t>(value), &result);
  return result;
}

napi_value MakeBool(napi_env env, bool value) {
  napi_value result = nullptr;
  napi_get_boolean(env, value, &result);
  return result;
}

napi_value MakeInt32(napi_env env, int32_t value) {
  napi_value result = nullptr;
  napi_create_int32(env, value, &result);
  return result;
}

// Sets a named property on `object`, logging (but not throwing) on failure so a
// partially built result degrades gracefully instead of crashing the module.
void SetProp(napi_env env, napi_value object, const char* name,
             napi_value value) {
  if (value == nullptr) {
    return;
  }
  if (napi_set_named_property(env, object, name, value) != napi_ok) {
    OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                 "failed to set property %{public}s", name);
  }
}

void SetStringProp(napi_env env, napi_value object, const char* name,
                   const std::string& value) {
  SetProp(env, object, name, MakeString(env, value));
}

void SetBoolProp(napi_env env, napi_value object, const char* name, bool value) {
  SetProp(env, object, name, MakeBool(env, value));
}

void SetIntProp(napi_env env, napi_value object, const char* name, int value) {
  SetProp(env, object, name, MakeInt32(env, value));
}

// ---------------------------------------------------------------------------
// result builders
// ---------------------------------------------------------------------------

napi_value BuildCandidate(napi_env env,
                          const rime_ohos::Candidate& candidate) {
  napi_value object = nullptr;
  napi_create_object(env, &object);
  SetStringProp(env, object, "text", candidate.text);
  SetStringProp(env, object, "comment", candidate.comment);
  return object;
}

napi_value BuildContext(napi_env env, const rime_ohos::Context& context) {
  if (!context.valid) {
    napi_value null_value = nullptr;
    napi_get_null(env, &null_value);
    return null_value;
  }

  napi_value object = nullptr;
  napi_create_object(env, &object);

  napi_value composition = nullptr;
  napi_create_object(env, &composition);
  SetIntProp(env, composition, "length", context.composition.length);
  SetIntProp(env, composition, "cursorPos", context.composition.cursor_pos);
  SetIntProp(env, composition, "selStart", context.composition.sel_start);
  SetIntProp(env, composition, "selEnd", context.composition.sel_end);
  SetStringProp(env, composition, "preedit", context.composition.preedit);
  SetProp(env, object, "composition", composition);

  napi_value menu = nullptr;
  napi_create_object(env, &menu);
  SetIntProp(env, menu, "pageSize", context.menu.page_size);
  SetIntProp(env, menu, "pageNo", context.menu.page_no);
  SetBoolProp(env, menu, "isLastPage", context.menu.is_last_page);
  SetIntProp(env, menu, "highlightedCandidateIndex",
             context.menu.highlighted_candidate_index);
  SetIntProp(env, menu, "numCandidates", context.menu.num_candidates);
  SetStringProp(env, menu, "selectKeys", context.menu.select_keys);

  napi_value candidates = nullptr;
  napi_create_array_with_length(env, context.menu.candidates.size(),
                                &candidates);
  for (size_t candidate_index = 0;
       candidate_index < context.menu.candidates.size(); ++candidate_index) {
    napi_set_element(
        env, candidates, static_cast<uint32_t>(candidate_index),
        BuildCandidate(env, context.menu.candidates[candidate_index]));
  }
  SetProp(env, menu, "candidates", candidates);
  SetProp(env, object, "menu", menu);

  SetStringProp(env, object, "commitTextPreview",
                context.commit_text_preview);
  return object;
}

napi_value BuildStatus(napi_env env, const rime_ohos::Status& status) {
  if (!status.valid) {
    napi_value null_value = nullptr;
    napi_get_null(env, &null_value);
    return null_value;
  }

  napi_value object = nullptr;
  napi_create_object(env, &object);
  SetStringProp(env, object, "schemaId", status.schema_id);
  SetStringProp(env, object, "schemaName", status.schema_name);
  SetBoolProp(env, object, "isDisabled", status.is_disabled);
  SetBoolProp(env, object, "isComposing", status.is_composing);
  SetBoolProp(env, object, "isAsciiMode", status.is_ascii_mode);
  SetBoolProp(env, object, "isFullShape", status.is_full_shape);
  SetBoolProp(env, object, "isSimplified", status.is_simplified);
  SetBoolProp(env, object, "isTraditional", status.is_traditional);
  SetBoolProp(env, object, "isAsciiPunct", status.is_ascii_punct);
  return object;
}

// ---------------------------------------------------------------------------
// notification delivery (librime thread -> JS thread)
// ---------------------------------------------------------------------------

struct NotificationPayload {
  uint64_t session_id;
  std::string type;
  std::string value;
};

napi_threadsafe_function g_notification_tsfn = nullptr;

void CallJsNotification(napi_env env, napi_value js_callback, void* context,
                        void* data) {
  std::unique_ptr<NotificationPayload> payload(
      static_cast<NotificationPayload*>(data));
  if (env == nullptr || js_callback == nullptr || !payload) {
    return;
  }

  napi_value object = nullptr;
  napi_create_object(env, &object);
  SetProp(env, object, "sessionId", MakeUint64(env, payload->session_id));
  SetStringProp(env, object, "type", payload->type);
  SetStringProp(env, object, "value", payload->value);

  napi_value global = nullptr;
  napi_get_global(env, &global);
  napi_value undefined = nullptr;
  napi_get_undefined(env, &undefined);
  napi_call_function(env, global, js_callback, 1, &object, nullptr);
  (void)undefined;
}

// Runs on whichever thread raises the notification: librime's own notification
// thread, or the JS thread while setNotificationCallback() replays the backlog.
void DispatchNotification(const rime_ohos::Notification& notification) {
  if (g_notification_tsfn == nullptr) {
    return;
  }
  auto* payload = new NotificationPayload{notification.session_id,
                                          notification.type,
                                          notification.value};
  if (napi_call_threadsafe_function(g_notification_tsfn, payload,
                                    napi_tsfn_nonblocking) != napi_ok) {
    delete payload;
  }
}

// ---------------------------------------------------------------------------
// exported methods
// ---------------------------------------------------------------------------

// configure(config: { sharedDataDir, userDataDir, logDir?, appName?,
// minLogLevel? }): boolean
napi_value RimeConfigure(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "configure(config) requires a config object");
  }

  napi_value shared_property = nullptr;
  napi_value user_property = nullptr;
  napi_get_named_property(env, args[0], "sharedDataDir", &shared_property);
  napi_get_named_property(env, args[0], "userDataDir", &user_property);

  std::string shared_dir;
  std::string user_dir;
  if (!GetString(env, shared_property, &shared_dir) ||
      !GetString(env, user_property, &user_dir)) {
    return ThrowTypeError(env,
                          "config.sharedDataDir and config.userDataDir must be "
                          "non-empty strings");
  }

  napi_value log_value = nullptr;
  napi_get_named_property(env, args[0], "logDir", &log_value);
  std::string log_dir;  // filled below when the caller supplies one
  if (log_value != nullptr) {
    napi_valuetype type = napi_undefined;
    napi_typeof(env, log_value, &type);
    if (type == napi_string) {
      GetString(env, log_value, &log_dir);
    }
  }

  napi_value app_value = nullptr;
  napi_get_named_property(env, args[0], "appName", &app_value);
  std::string app_name = "rime.fcitx5_ohos";
  if (app_value != nullptr) {
    napi_valuetype type = napi_undefined;
    napi_typeof(env, app_value, &type);
    if (type == napi_string) {
      GetString(env, app_value, &app_name);
    }
  }

  napi_value level_value = nullptr;
  napi_get_named_property(env, args[0], "minLogLevel", &level_value);
  int32_t min_log_level = 1;  // warnings and above by default
  if (level_value != nullptr) {
    napi_valuetype type = napi_undefined;
    napi_typeof(env, level_value, &type);
    if (type == napi_number) {
      GetInt32(env, level_value, &min_log_level);
    }
  }

  rime_ohos::RimeEngine::Instance().Configure(shared_dir, user_dir, log_dir,
                                              app_name, min_log_level);
  return MakeBool(env, true);
}

napi_value RimeInitialize(napi_env env, napi_callback_info info) {
  return MakeBool(env, rime_ohos::RimeEngine::Instance().Initialize());
}

napi_value RimeFinalize(napi_env env, napi_callback_info info) {
  rime_ohos::RimeEngine::Instance().Finalize();
  return MakeBool(env, true);
}

// hasComponent(name: string): boolean
//
// Lets the UI report whether a plugin actually registered its component, which
// is otherwise invisible: a schema referencing a missing component still loads,
// it just silently does less.
napi_value RimeHasComponent(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "hasComponent(name) requires an argument");
  }
  std::string name;
  if (!GetString(env, args[0], &name)) {
    return ThrowTypeError(env, "name must be a string");
  }
  return MakeBool(env, rime_ohos::RimeEngine::Instance().HasComponent(name));
}

// getGrammarLanguage(sessionId: number): string
napi_value RimeGetGrammarLanguage(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "getGrammarLanguage(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }
  return MakeString(
      env, rime_ohos::RimeEngine::Instance().GetGrammarLanguage(session));
}

napi_value RimeRestart(napi_env env, napi_callback_info info) {
  return MakeBool(env, rime_ohos::RimeEngine::Instance().Restart());
}

napi_value RimeIsInitialized(napi_env env, napi_callback_info info) {
  return MakeBool(env, rime_ohos::RimeEngine::Instance().IsInitialized());
}

napi_value RimeDeploy(napi_env env, napi_callback_info info) {
  return MakeBool(env, rime_ohos::RimeEngine::Instance().Deploy(true));
}

// startMaintenance(fullCheck: boolean): boolean
napi_value RimeStartMaintenance(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  bool full_check = true;
  if (argc >= 1) {
    GetBool(env, args[0], &full_check);
  }
  return MakeBool(
      env, rime_ohos::RimeEngine::Instance().StartMaintenance(full_check));
}

napi_value RimeIsMaintenanceMode(napi_env env, napi_callback_info info) {
  return MakeBool(env, rime_ohos::RimeEngine::Instance().IsMaintenanceMode());
}

napi_value RimeJoinMaintenanceThread(napi_env env, napi_callback_info info) {
  rime_ohos::RimeEngine::Instance().JoinMaintenanceThread();
  return MakeBool(env, true);
}

napi_value RimeCreateSession(napi_env env, napi_callback_info info) {
  const uint64_t session =
      rime_ohos::RimeEngine::Instance().CreateSession();
  if (session == 0) {
    return ThrowError(env, "createSession() failed: engine is not ready");
  }
  return MakeUint64(env, session);
}

// destroySession(sessionId: number): boolean
napi_value RimeDestroySession(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "destroySession(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }
  return MakeBool(env,
                  rime_ohos::RimeEngine::Instance().DestroySession(session));
}

// processKey(sessionId: number, keysym: number, modifiers: number): boolean
napi_value RimeProcessKey(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 3) {
    return ThrowTypeError(
        env, "processKey(sessionId, keysym, modifiers) requires 3 arguments");
  }
  uint64_t session = 0;
  int32_t keysym = 0;
  int32_t modifiers = 0;
  if (!GetUint64(env, args[0], &session) || !GetInt32(env, args[1], &keysym) ||
      !GetInt32(env, args[2], &modifiers)) {
    return ThrowTypeError(env,
                          "processKey expects (number, number, number)");
  }
  return MakeBool(env, rime_ohos::RimeEngine::Instance().ProcessKey(
                           session, keysym, modifiers));
}

napi_value RimeCommitComposition(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "commitComposition(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }
  return MakeBool(
      env, rime_ohos::RimeEngine::Instance().CommitComposition(session));
}

napi_value RimeClearComposition(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "clearComposition(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }
  rime_ohos::RimeEngine::Instance().ClearComposition(session);
  return MakeBool(env, true);
}

napi_value RimeGetContext(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "getContext(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }
  return BuildContext(env,
                      rime_ohos::RimeEngine::Instance().GetContext(session));
}

// getCandidateList(sessionId: number): { index, text, comment }[]
//
// The whole candidate list rather than the current page, so the keyboard can
// paginate by how wide the candidates actually are.  `index` is the global
// index that selectCandidate() expects.
napi_value RimeGetCandidateList(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "getCandidateList(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }

  const auto candidates =
      rime_ohos::RimeEngine::Instance().GetCandidateList(session);
  napi_value array = nullptr;
  napi_create_array_with_length(env, candidates.size(), &array);
  for (size_t candidate_index = 0; candidate_index < candidates.size();
       ++candidate_index) {
    napi_value item = nullptr;
    napi_create_object(env, &item);
    SetProp(env, item, "index",
            MakeUint64(env, candidates[candidate_index].index));
    SetStringProp(env, item, "text", candidates[candidate_index].text);
    SetStringProp(env, item, "comment", candidates[candidate_index].comment);
    napi_set_element(env, array, static_cast<uint32_t>(candidate_index), item);
  }
  return array;
}

// getCommit(sessionId: number): string | null
napi_value RimeGetCommit(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "getCommit(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }

  std::string text;
  if (!rime_ohos::RimeEngine::Instance().GetCommit(session, &text)) {
    napi_value null_value = nullptr;
    napi_get_null(env, &null_value);
    return null_value;
  }
  return MakeString(env, text);
}

napi_value RimeGetStatus(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "getStatus(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }
  return BuildStatus(env,
                     rime_ohos::RimeEngine::Instance().GetStatus(session));
}

napi_value RimeSelectCandidate(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 2) {
    return ThrowTypeError(env,
                          "selectCandidate(sessionId, index) requires 2 arguments");
  }
  uint64_t session = 0;
  int32_t index = 0;
  if (!GetUint64(env, args[0], &session) || !GetInt32(env, args[1], &index)) {
    return ThrowTypeError(env, "selectCandidate expects (number, number)");
  }
  return MakeBool(env, rime_ohos::RimeEngine::Instance().SelectCandidate(
                           session, static_cast<size_t>(index)));
}

napi_value RimeDeleteCandidate(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 2) {
    return ThrowTypeError(env,
                          "deleteCandidate(sessionId, index) requires 2 arguments");
  }
  uint64_t session = 0;
  int32_t index = 0;
  if (!GetUint64(env, args[0], &session) || !GetInt32(env, args[1], &index)) {
    return ThrowTypeError(env, "deleteCandidate expects (number, number)");
  }
  return MakeBool(env, rime_ohos::RimeEngine::Instance().DeleteCandidate(
                           session, static_cast<size_t>(index)));
}

// changePage(sessionId: number, backward: boolean): boolean
napi_value RimeChangePage(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 2) {
    return ThrowTypeError(env,
                          "changePage(sessionId, backward) requires 2 arguments");
  }
  uint64_t session = 0;
  bool backward = false;
  if (!GetUint64(env, args[0], &session) || !GetBool(env, args[1], &backward)) {
    return ThrowTypeError(env, "changePage expects (number, boolean)");
  }
  return MakeBool(
      env, rime_ohos::RimeEngine::Instance().ChangePage(session, backward));
}

// setOption(sessionId: number, name: string, value: boolean): void
napi_value RimeSetOption(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 3) {
    return ThrowTypeError(
        env, "setOption(sessionId, name, value) requires 3 arguments");
  }
  uint64_t session = 0;
  std::string name;
  bool value = false;
  if (!GetUint64(env, args[0], &session) || !GetString(env, args[1], &name) ||
      !GetBool(env, args[2], &value)) {
    return ThrowTypeError(env, "setOption expects (number, string, boolean)");
  }
  rime_ohos::RimeEngine::Instance().SetOption(session, name, value);
  napi_value undefined = nullptr;
  napi_get_undefined(env, &undefined);
  return undefined;
}

napi_value RimeGetOption(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 2) {
    return ThrowTypeError(env,
                          "getOption(sessionId, name) requires 2 arguments");
  }
  uint64_t session = 0;
  std::string name;
  if (!GetUint64(env, args[0], &session) || !GetString(env, args[1], &name)) {
    return ThrowTypeError(env, "getOption expects (number, string)");
  }
  return MakeBool(env,
                  rime_ohos::RimeEngine::Instance().GetOption(session, name));
}

napi_value RimeGetSchemaList(napi_env env, napi_callback_info info) {
  const auto schemas = rime_ohos::RimeEngine::Instance().GetSchemaList();
  napi_value array = nullptr;
  napi_create_array_with_length(env, schemas.size(), &array);
  for (size_t schema_index = 0; schema_index < schemas.size(); ++schema_index) {
    napi_value item = nullptr;
    napi_create_object(env, &item);
    SetStringProp(env, item, "schemaId", schemas[schema_index].schema_id);
    SetStringProp(env, item, "name", schemas[schema_index].name);
    napi_set_element(env, array, static_cast<uint32_t>(schema_index), item);
  }
  return array;
}

napi_value RimeGetCurrentSchema(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "getCurrentSchema(sessionId) requires an argument");
  }
  uint64_t session = 0;
  if (!GetUint64(env, args[0], &session)) {
    return ThrowTypeError(env, "sessionId must be a number");
  }
  return MakeString(env,
                    rime_ohos::RimeEngine::Instance().GetCurrentSchema(session));
}

napi_value RimeSelectSchema(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 2) {
    return ThrowTypeError(env,
                          "selectSchema(sessionId, schemaId) requires 2 arguments");
  }
  uint64_t session = 0;
  std::string schema_id;
  if (!GetUint64(env, args[0], &session) ||
      !GetString(env, args[1], &schema_id)) {
    return ThrowTypeError(env, "selectSchema expects (number, string)");
  }
  return MakeBool(env, rime_ohos::RimeEngine::Instance().SelectSchema(
                           session, schema_id));
}

// getSchemaSwitches(schemaId: string): { name, options, states, reset }[]
//
// The toggle list a schema declares in its `switches:` block, which is what the
// settings panel is built from.
napi_value RimeGetSchemaSwitches(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "getSchemaSwitches(schemaId) requires an argument");
  }
  std::string schema_id;
  if (!GetString(env, args[0], &schema_id)) {
    return ThrowTypeError(env, "schemaId must be a string");
  }

  const auto switches =
      rime_ohos::RimeEngine::Instance().GetSchemaSwitches(schema_id);
  napi_value array = nullptr;
  napi_create_array_with_length(env, switches.size(), &array);
  for (size_t switch_index = 0; switch_index < switches.size();
       ++switch_index) {
    napi_value item = nullptr;
    napi_create_object(env, &item);
    SetStringProp(env, item, "name", switches[switch_index].name);
    SetProp(env, item, "reset", MakeInt32(env, switches[switch_index].reset));

    napi_value options = nullptr;
    napi_create_array_with_length(env, switches[switch_index].options.size(),
                                  &options);
    for (size_t option_index = 0;
         option_index < switches[switch_index].options.size(); ++option_index) {
      napi_set_element(
          env, options, static_cast<uint32_t>(option_index),
          MakeString(env, switches[switch_index].options[option_index]));
    }
    SetProp(env, item, "options", options);

    napi_value states = nullptr;
    napi_create_array_with_length(env, switches[switch_index].states.size(),
                                  &states);
    for (size_t state_index = 0;
         state_index < switches[switch_index].states.size(); ++state_index) {
      napi_set_element(
          env, states, static_cast<uint32_t>(state_index),
          MakeString(env, switches[switch_index].states[state_index]));
    }
    SetProp(env, item, "states", states);
    napi_set_element(env, array, static_cast<uint32_t>(switch_index), item);
  }
  return array;
}

napi_value RimeGetVersion(napi_env env, napi_callback_info info) {
  return MakeString(env, rime_ohos::RimeEngine::Instance().GetVersion());
}

napi_value RimeGetUserDataDir(napi_env env, napi_callback_info info) {
  return MakeString(env, rime_ohos::RimeEngine::Instance().GetUserDataDir());
}

napi_value RimeGetSharedDataDir(napi_env env, napi_callback_info info) {
  return MakeString(env, rime_ohos::RimeEngine::Instance().GetSharedDataDir());
}

// setNotificationCallback(callback: (n: RimeNotification) => void): void
napi_value RimeSetNotificationCallback(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      argc < 1) {
    return ThrowTypeError(env, "setNotificationCallback(callback) requires a function");
  }

  napi_valuetype type = napi_undefined;
  napi_typeof(env, args[0], &type);
  if (type != napi_function) {
    return ThrowTypeError(env, "notification callback must be a function");
  }

  if (g_notification_tsfn != nullptr) {
    napi_release_threadsafe_function(g_notification_tsfn, napi_tsfn_release);
    g_notification_tsfn = nullptr;
  }

  napi_value resource_name = nullptr;
  napi_create_string_utf8(env, "RimeNotification", NAPI_AUTO_LENGTH,
                          &resource_name);
  if (napi_create_threadsafe_function(env, args[0], nullptr, resource_name,
                                      /*max_queue_size=*/64,
                                      /*initial_thread_count=*/1, nullptr,
                                      nullptr, nullptr, CallJsNotification,
                                      &g_notification_tsfn) != napi_ok) {
    g_notification_tsfn = nullptr;
    return ThrowError(env, "failed to create notification callback");
  }

  rime_ohos::RimeEngine::Instance().SetNotificationSink(DispatchNotification);
  napi_value undefined = nullptr;
  napi_get_undefined(env, &undefined);
  return undefined;
}

// pollNotification(): RimeNotification | null
//
// Fallback for callers that prefer polling over the callback.
napi_value RimePollNotification(napi_env env, napi_callback_info info) {
  rime_ohos::Notification notification;
  if (!rime_ohos::RimeEngine::Instance().PollNotification(&notification)) {
    napi_value null_value = nullptr;
    napi_get_null(env, &null_value);
    return null_value;
  }
  napi_value object = nullptr;
  napi_create_object(env, &object);
  SetProp(env, object, "sessionId", MakeUint64(env, notification.session_id));
  SetStringProp(env, object, "type", notification.type);
  SetStringProp(env, object, "value", notification.value);
  return object;
}

// ---------------------------------------------------------------------------
// module registration
// ---------------------------------------------------------------------------

napi_value RegisterFunction(napi_env env, napi_value exports, const char* name,
                            napi_callback callback) {
  napi_value function = nullptr;
  napi_create_function(env, name, NAPI_AUTO_LENGTH, callback, nullptr,
                       &function);
  napi_set_named_property(env, exports, name, function);
  return exports;
}

// Publishes librime's RimeModifier constants so ArkTS never has to duplicate
// them.  The values are fixed by librime's public API (see
// librime/src/rime/key_table.h); the high bits are XKB-specific.
napi_value BuildModifierConstants(napi_env env) {
  struct Entry {
    const char* name;
    int32_t value;
  };
  // clang-format off
  const Entry entries[] = {
      {"NONE",          0},
      {"SHIFT",         1 << 0},   // kShiftMask
      {"LOCK",          1 << 1},   // kLockMask   (Caps Lock)
      {"CONTROL",       1 << 2},   // kControlMask
      {"ALT",           1 << 3},   // kAltMask == kMod1Mask
      {"MOD2",          1 << 4},
      {"MOD3",          1 << 5},
      {"MOD4",          1 << 6},
      {"MOD5",          1 << 7},
      {"SUPER",         1 << 26},  // kSuperMask
      {"HYPER",         1 << 27},  // kHyperMask
      {"META",          1 << 28},  // kMetaMask
      {"RELEASE",       1 << 30},  // kReleaseMask
      {"MODIFIER_MASK", 0x5f001fff},
  };
  // clang-format on

  napi_value object = nullptr;
  napi_create_object(env, &object);
  for (const auto& entry : entries) {
    SetProp(env, object, entry.name, MakeInt32(env, entry.value));
  }
  return object;
}

napi_value Init(napi_env env, napi_value exports) {
  RegisterFunction(env, exports, "configure", RimeConfigure);
  RegisterFunction(env, exports, "initialize", RimeInitialize);
  RegisterFunction(env, exports, "finalize", RimeFinalize);
  RegisterFunction(env, exports, "restart", RimeRestart);
  RegisterFunction(env, exports, "hasComponent", RimeHasComponent);
  RegisterFunction(env, exports, "getGrammarLanguage", RimeGetGrammarLanguage);
  RegisterFunction(env, exports, "isInitialized", RimeIsInitialized);

  RegisterFunction(env, exports, "deploy", RimeDeploy);
  RegisterFunction(env, exports, "startMaintenance", RimeStartMaintenance);
  RegisterFunction(env, exports, "isMaintenanceMode", RimeIsMaintenanceMode);
  RegisterFunction(env, exports, "joinMaintenanceThread",
                   RimeJoinMaintenanceThread);

  RegisterFunction(env, exports, "createSession", RimeCreateSession);
  RegisterFunction(env, exports, "destroySession", RimeDestroySession);
  RegisterFunction(env, exports, "processKey", RimeProcessKey);
  RegisterFunction(env, exports, "commitComposition", RimeCommitComposition);
  RegisterFunction(env, exports, "clearComposition", RimeClearComposition);

  RegisterFunction(env, exports, "getContext", RimeGetContext);
  RegisterFunction(env, exports, "getCandidateList", RimeGetCandidateList);
  RegisterFunction(env, exports, "getCommit", RimeGetCommit);
  RegisterFunction(env, exports, "getStatus", RimeGetStatus);
  RegisterFunction(env, exports, "selectCandidate", RimeSelectCandidate);
  RegisterFunction(env, exports, "deleteCandidate", RimeDeleteCandidate);
  RegisterFunction(env, exports, "changePage", RimeChangePage);

  RegisterFunction(env, exports, "setOption", RimeSetOption);
  RegisterFunction(env, exports, "getOption", RimeGetOption);
  RegisterFunction(env, exports, "getSchemaList", RimeGetSchemaList);
  RegisterFunction(env, exports, "getCurrentSchema", RimeGetCurrentSchema);
  RegisterFunction(env, exports, "selectSchema", RimeSelectSchema);

  RegisterFunction(env, exports, "getSchemaSwitches", RimeGetSchemaSwitches);
  RegisterFunction(env, exports, "getVersion", RimeGetVersion);
  RegisterFunction(env, exports, "getUserDataDir", RimeGetUserDataDir);
  RegisterFunction(env, exports, "getSharedDataDir", RimeGetSharedDataDir);

  RegisterFunction(env, exports, "setNotificationCallback",
                   RimeSetNotificationCallback);
  RegisterFunction(env, exports, "pollNotification", RimePollNotification);

  SetProp(env, exports, "RimeModifier", BuildModifierConstants(env));

  return exports;
}

}  // namespace

static napi_module g_rime_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterRimeModule() {
  napi_module_register(&g_rime_module);
}
