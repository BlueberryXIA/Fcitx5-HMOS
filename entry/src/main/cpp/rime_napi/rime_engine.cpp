// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Haochen Xia
//
#include "rime_engine.h"

#include <rime/registry.h>

#include <cstring>
#include <utility>

namespace rime_ohos {
namespace {

// librime hands back UTF-8 C strings that may be null.
std::string NullSafeString(const char* value) {
  return value ? std::string(value) : std::string();
}

}  // namespace

RimeEngine& RimeEngine::Instance() {
  static RimeEngine instance;
  return instance;
}

RimeEngine::RimeEngine() = default;
RimeEngine::~RimeEngine() = default;

// ---------------------------------------------------------------------------
// lifecycle
// ---------------------------------------------------------------------------

void RimeEngine::Configure(const std::string& shared_data_dir,
                           const std::string& user_data_dir,
                           const std::string& log_dir,
                           const std::string& app_name,
                           int min_log_level) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (initialized_) {
    return;
  }

  shared_data_dir_ = shared_data_dir;
  user_data_dir_ = user_data_dir;
  log_dir_ = log_dir;
  app_name_ = app_name;
  min_log_level_ = min_log_level;

  // Keep the backing strings alive first: traits_ stores raw pointers into
  // traits_strings_, and std::deque never moves existing elements.
  traits_strings_.clear();
  auto store_traits_string = [this](const std::string& text) -> const char* {
    traits_strings_.push_back(text);
    return traits_strings_.back().c_str();
  };

  const char* shared_data_dir_ptr = store_traits_string(shared_data_dir_);
  const char* user_data_dir_ptr = store_traits_string(user_data_dir_);
  const char* log_dir_ptr = store_traits_string(log_dir_);
  const char* app_name_ptr = store_traits_string(app_name_);
  const char* distribution_name = store_traits_string("Fcitx5 for HarmonyOS");
  const char* distribution_code = store_traits_string("fcitx5-ohos");
  const char* distribution_version = store_traits_string("0.1.0");

  std::memset(&traits_, 0, sizeof(traits_));
  RIME_STRUCT_INIT(RimeTraits, traits_);
  traits_.shared_data_dir = shared_data_dir_ptr;
  traits_.user_data_dir = user_data_dir_ptr;
  traits_.distribution_name = distribution_name;
  traits_.distribution_code_name = distribution_code;
  traits_.distribution_version = distribution_version;
  // librime expects "rime.<client>" so that it can age out stale log files.
  traits_.app_name = app_name_ptr;
  traits_.modules = nullptr;
  traits_.min_log_level = min_log_level_;
  traits_.log_dir = log_dir_ptr;
  traits_.prebuilt_data_dir = nullptr;  // defaults to <shared>/build
  traits_.staging_dir = nullptr;        // defaults to <user>/build

  configured_ = true;
}

bool RimeEngine::Initialize() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (initialized_) {
    return true;
  }
  if (!configured_) {
    return false;
  }

  api_ = rime_get_api();
  if (api_ == nullptr) {
    return false;
  }

  api_->setup(&traits_);
  api_->set_notification_handler(&RimeEngine::NotificationHandler, this);
  api_->initialize(&traits_);

  initialized_ = true;
  return true;
}

void RimeEngine::Finalize() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return;
  }
  api_->finalize();
  initialized_ = false;
  // `setup` may be called again after finalize, so leave configured_ intact.
}

std::string RimeEngine::GetGrammarLanguage(uint64_t session_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return {};
  }
  if (!RIME_API_AVAILABLE(api_, get_current_schema) ||
      !RIME_API_AVAILABLE(api_, schema_open) ||
      !RIME_API_AVAILABLE(api_, config_get_cstring) ||
      !RIME_API_AVAILABLE(api_, config_close)) {
    return {};
  }

  char schema_id_buffer[256] = {0};
  if (api_->get_current_schema(static_cast<RimeSessionId>(session_id),
                               schema_id_buffer,
                               sizeof(schema_id_buffer)) == 0) {
    return {};
  }

  RimeConfig config = {0};
  if (api_->schema_open(schema_id_buffer, &config) == 0) {
    return {};
  }
  const char* grammar_language =
      api_->config_get_cstring(&config, "grammar/language");
  const std::string language = NullSafeString(grammar_language);
  api_->config_close(&config);
  return language;
}

bool RimeEngine::HasComponent(const std::string& name) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || name.empty()) {
    return false;
  }
  return rime::Registry::instance().Find(name) != nullptr;
}

bool RimeEngine::Restart() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!configured_) {
    return false;
  }

  if (initialized_ && api_ != nullptr) {
    api_->finalize();
    initialized_ = false;
  }

  // rime_get_api() hands out a pointer to a static structure, but re-fetch it
  // rather than assume it survives finalize().
  api_ = rime_get_api();
  if (api_ == nullptr) {
    return false;
  }

  api_->setup(&traits_);
  api_->set_notification_handler(&RimeEngine::NotificationHandler, this);
  api_->initialize(&traits_);
  initialized_ = true;
  return true;
}

bool RimeEngine::IsInitialized() {
  std::lock_guard<std::mutex> lock(mutex_);
  return initialized_;
}

bool RimeEngine::Deploy(bool full_check) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  // `full_check` is not forwarded: librime's deploy() takes no argument and
  // always runs installation_update + workspace_update + user_dict_upgrade,
  // which is also what a fresh install needs.
  const Bool deployed = api_->deploy();
  (void)full_check;
  return deployed != 0;
}

bool RimeEngine::StartMaintenance(bool full_check) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  return api_->start_maintenance(full_check ? True : False) != 0;
}

bool RimeEngine::IsMaintenanceMode() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  return api_->is_maintenance_mode() != 0;
}

void RimeEngine::JoinMaintenanceThread() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return;
  }
  api_->join_maintenance_thread();
}

// ---------------------------------------------------------------------------
// sessions
// ---------------------------------------------------------------------------

uint64_t RimeEngine::CreateSession() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return 0;
  }
  return static_cast<uint64_t>(api_->create_session());
}

bool RimeEngine::DestroySession(uint64_t session_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  return api_->destroy_session(static_cast<RimeSessionId>(session_id)) != 0;
}

bool RimeEngine::FindSession(uint64_t session_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  return api_->find_session(static_cast<RimeSessionId>(session_id)) != 0;
}

void RimeEngine::DestroyAllSessions() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return;
  }
  api_->cleanup_all_sessions();
}

// ---------------------------------------------------------------------------
// input
// ---------------------------------------------------------------------------

bool RimeEngine::ProcessKey(uint64_t session_id, int keysym, int modifiers) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  return api_->process_key(static_cast<RimeSessionId>(session_id), keysym,
                           modifiers) != 0;
}

bool RimeEngine::CommitComposition(uint64_t session_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  return api_->commit_composition(static_cast<RimeSessionId>(session_id)) != 0;
}

void RimeEngine::ClearComposition(uint64_t session_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return;
  }
  api_->clear_composition(static_cast<RimeSessionId>(session_id));
}

bool RimeEngine::SetInput(uint64_t session_id, const std::string& input) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  if (!RIME_API_AVAILABLE(api_, set_input)) {
    return false;
  }
  return api_->set_input(static_cast<RimeSessionId>(session_id),
                         input.c_str()) != 0;
}

// ---------------------------------------------------------------------------
// output
// ---------------------------------------------------------------------------

Context RimeEngine::GetContext(uint64_t session_id) {
  Context context;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return context;
  }

  RIME_STRUCT(RimeContext, rime_context);
  if (api_->get_context(static_cast<RimeSessionId>(session_id),
                        &rime_context) == 0) {
    return context;
  }

  context.valid = true;
  context.composition.length = rime_context.composition.length;
  context.composition.cursor_pos = rime_context.composition.cursor_pos;
  context.composition.sel_start = rime_context.composition.sel_start;
  context.composition.sel_end = rime_context.composition.sel_end;
  context.composition.preedit =
      NullSafeString(rime_context.composition.preedit);
  context.commit_text_preview =
      NullSafeString(rime_context.commit_text_preview);

  context.menu.page_size = rime_context.menu.page_size;
  context.menu.page_no = rime_context.menu.page_no;
  context.menu.is_last_page = rime_context.menu.is_last_page != 0;
  context.menu.highlighted_candidate_index =
      rime_context.menu.highlighted_candidate_index;
  context.menu.num_candidates = rime_context.menu.num_candidates;
  context.menu.select_keys = NullSafeString(rime_context.menu.select_keys);

  if (rime_context.menu.candidates != nullptr) {
    context.menu.candidates.reserve(
        static_cast<size_t>(rime_context.menu.num_candidates));
    for (int candidate_index = 0;
         candidate_index < rime_context.menu.num_candidates;
         ++candidate_index) {
      Candidate candidate;
      candidate.text = NullSafeString(
          rime_context.menu.candidates[candidate_index].text);
      candidate.comment = NullSafeString(
          rime_context.menu.candidates[candidate_index].comment);
      context.menu.candidates.push_back(std::move(candidate));
    }
  }

  api_->free_context(&rime_context);
  return context;
}

std::vector<CandidateListItem> RimeEngine::GetCandidateList(uint64_t session_id) {
  std::vector<CandidateListItem> candidates;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return candidates;
  }
  if (!RIME_API_AVAILABLE(api_, candidate_list_begin) ||
      !RIME_API_AVAILABLE(api_, candidate_list_next) ||
      !RIME_API_AVAILABLE(api_, candidate_list_end)) {
    return candidates;
  }

  RimeCandidateListIterator candidate_iterator;
  std::memset(&candidate_iterator, 0, sizeof(candidate_iterator));
  const RimeSessionId session = static_cast<RimeSessionId>(session_id);
  if (api_->candidate_list_begin(session, &candidate_iterator) == 0) {
    return candidates;
  }

  while (api_->candidate_list_next(&candidate_iterator) != 0) {
    CandidateListItem entry;
    entry.index = static_cast<size_t>(candidate_iterator.index);
    entry.text = NullSafeString(candidate_iterator.candidate.text);
    entry.comment = NullSafeString(candidate_iterator.candidate.comment);
    candidates.push_back(std::move(entry));
  }
  api_->candidate_list_end(&candidate_iterator);
  return candidates;
}

bool RimeEngine::GetCommit(uint64_t session_id, std::string* text) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }

  RIME_STRUCT(RimeCommit, commit);
  if (api_->get_commit(static_cast<RimeSessionId>(session_id), &commit) == 0) {
    return false;
  }
  if (text != nullptr) {
    *text = NullSafeString(commit.text);
  }
  api_->free_commit(&commit);
  return true;
}

Status RimeEngine::GetStatus(uint64_t session_id) {
  Status status;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return status;
  }

  RIME_STRUCT(RimeStatus, rime_status);
  if (api_->get_status(static_cast<RimeSessionId>(session_id), &rime_status) ==
      0) {
    return status;
  }

  status.valid = true;
  status.schema_id = NullSafeString(rime_status.schema_id);
  status.schema_name = NullSafeString(rime_status.schema_name);
  status.is_disabled = rime_status.is_disabled != 0;
  status.is_composing = rime_status.is_composing != 0;
  status.is_ascii_mode = rime_status.is_ascii_mode != 0;
  status.is_full_shape = rime_status.is_full_shape != 0;
  status.is_simplified = rime_status.is_simplified != 0;
  status.is_traditional = rime_status.is_traditional != 0;
  status.is_ascii_punct = rime_status.is_ascii_punct != 0;

  api_->free_status(&rime_status);
  return status;
}

bool RimeEngine::SelectCandidate(uint64_t session_id, size_t index) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  if (!RIME_API_AVAILABLE(api_, select_candidate)) {
    return false;
  }
  return api_->select_candidate(static_cast<RimeSessionId>(session_id), index) !=
         0;
}

bool RimeEngine::DeleteCandidate(uint64_t session_id, size_t index) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  if (!RIME_API_AVAILABLE(api_, delete_candidate)) {
    return false;
  }
  return api_->delete_candidate(static_cast<RimeSessionId>(session_id), index) !=
         0;
}

bool RimeEngine::HighlightCandidate(uint64_t session_id, size_t index) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  if (!RIME_API_AVAILABLE(api_, highlight_candidate)) {
    return false;
  }
  return api_->highlight_candidate(static_cast<RimeSessionId>(session_id),
                                   index) != 0;
}

bool RimeEngine::ChangePage(uint64_t session_id, bool backward) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  if (RIME_API_AVAILABLE(api_, change_page)) {
    return api_->change_page(static_cast<RimeSessionId>(session_id),
                             backward ? True : False) != 0;
  }
  // Older librime only pages through dedicated keys.
  const int keysym = backward ? 0xff55 /* Page_Up */ : 0xff56 /* Page_Down */;
  return api_->process_key(static_cast<RimeSessionId>(session_id), keysym,
                           0) != 0;
}

// ---------------------------------------------------------------------------
// options / schemas
// ---------------------------------------------------------------------------

void RimeEngine::SetOption(uint64_t session_id,
                           const std::string& option,
                           bool value) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return;
  }
  api_->set_option(static_cast<RimeSessionId>(session_id), option.c_str(),
                   value ? True : False);
}

bool RimeEngine::GetOption(uint64_t session_id, const std::string& option) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  return api_->get_option(static_cast<RimeSessionId>(session_id),
                          option.c_str()) != 0;
}

std::vector<SchemaItem> RimeEngine::GetSchemaList() {
  std::vector<SchemaItem> schemas;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return schemas;
  }

  // RimeSchemaList is a plain struct, not one of librime's self-versioned
  // ones, so it must not go through RIME_STRUCT().
  RimeSchemaList rime_schema_list = {0};
  if (api_->get_schema_list(&rime_schema_list) == 0) {
    return schemas;
  }
  schemas.reserve(rime_schema_list.size);
  for (size_t schema_index = 0; schema_index < rime_schema_list.size;
       ++schema_index) {
    SchemaItem entry;
    entry.schema_id =
        NullSafeString(rime_schema_list.list[schema_index].schema_id);
    entry.name = NullSafeString(rime_schema_list.list[schema_index].name);
    schemas.push_back(std::move(entry));
  }
  api_->free_schema_list(&rime_schema_list);
  return schemas;
}

std::vector<SchemaSwitch> RimeEngine::GetSchemaSwitches(
    const std::string& schema_id) {
  std::vector<SchemaSwitch> switches;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr || schema_id.empty()) {
    return switches;
  }
  if (!RIME_API_AVAILABLE(api_, schema_open) ||
      !RIME_API_AVAILABLE(api_, config_begin_list) ||
      !RIME_API_AVAILABLE(api_, config_next) ||
      !RIME_API_AVAILABLE(api_, config_end) ||
      !RIME_API_AVAILABLE(api_, config_get_cstring)) {
    return switches;
  }

  // schema_open() resolves <schema_id>.schema.yaml with the user's
  // <schema_id>.custom.yaml patch already applied.
  RimeConfig config = {0};
  if (api_->schema_open(schema_id.c_str(), &config) == 0) {
    return switches;
  }

  RimeConfigIterator switch_iterator = {0};
  if (api_->config_begin_list(&switch_iterator, &config, "switches")) {
    while (api_->config_next(&switch_iterator) != 0) {
      // switch_iterator.path looks like "switches/@0".
      const std::string switch_path = NullSafeString(switch_iterator.path);
      if (switch_path.empty()) {
        continue;
      }

      SchemaSwitch schema_switch;
      schema_switch.name = NullSafeString(
          api_->config_get_cstring(&config, (switch_path + "/name").c_str()));

      // The radio form lists several mutually exclusive options instead of one
      // name.  Read those too, otherwise such a switch silently disappears.
      const std::string options_key = switch_path + "/options";
      size_t option_count = 0;
      if (RIME_API_AVAILABLE(api_, config_list_size)) {
        option_count = api_->config_list_size(&config, options_key.c_str());
      }
      for (size_t option_index = 0; option_index < option_count;
           ++option_index) {
        const std::string option_key =
            options_key + "/@" + std::to_string(option_index);
        const char* option =
            api_->config_get_cstring(&config, option_key.c_str());
        if (option != nullptr) {
          schema_switch.options.emplace_back(option);
        }
      }

      if (schema_switch.name.empty() && schema_switch.options.empty()) {
        continue;
      }

      if (RIME_API_AVAILABLE(api_, config_get_int)) {
        int reset_value = 0;
        if (api_->config_get_int(&config, (switch_path + "/reset").c_str(),
                                 &reset_value)) {
          schema_switch.reset = reset_value;
        }
      }

      const std::string states_key = switch_path + "/states";
      size_t state_count = 0;
      if (RIME_API_AVAILABLE(api_, config_list_size)) {
        state_count = api_->config_list_size(&config, states_key.c_str());
      }
      for (size_t state_index = 0; state_index < state_count; ++state_index) {
        const std::string state_key =
            states_key + "/@" + std::to_string(state_index);
        const char* state =
            api_->config_get_cstring(&config, state_key.c_str());
        if (state != nullptr) {
          schema_switch.states.emplace_back(state);
        }
      }

      switches.push_back(std::move(schema_switch));
    }
    api_->config_end(&switch_iterator);
  }

  api_->config_close(&config);
  return switches;
}

std::string RimeEngine::GetCurrentSchema(uint64_t session_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return {};
  }
  char schema_id_buffer[256] = {0};
  if (api_->get_current_schema(static_cast<RimeSessionId>(session_id),
                               schema_id_buffer,
                               sizeof(schema_id_buffer)) == 0) {
    return {};
  }
  return std::string(schema_id_buffer);
}

bool RimeEngine::SelectSchema(uint64_t session_id,
                              const std::string& schema_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!initialized_ || api_ == nullptr) {
    return false;
  }
  return api_->select_schema(static_cast<RimeSessionId>(session_id),
                             schema_id.c_str()) != 0;
}

// ---------------------------------------------------------------------------
// misc
// ---------------------------------------------------------------------------

std::string RimeEngine::GetVersion() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (api_ == nullptr) {
    // Safe to query without initialize(); it does not touch engine state.
    api_ = rime_get_api();
  }
  if (api_ == nullptr || !RIME_API_AVAILABLE(api_, get_version)) {
    return "unknown";
  }
  return NullSafeString(api_->get_version());
}

std::string RimeEngine::GetUserDataDir() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (api_ == nullptr) {
    api_ = rime_get_api();
  }
  if (api_ == nullptr) {
    return {};
  }
  char path_buffer[4096] = {0};
  if (RIME_API_AVAILABLE(api_, get_user_data_dir_s)) {
    api_->get_user_data_dir_s(path_buffer, sizeof(path_buffer));
    return std::string(path_buffer);
  }
  return NullSafeString(api_->get_user_data_dir());
}

std::string RimeEngine::GetSharedDataDir() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (api_ == nullptr) {
    api_ = rime_get_api();
  }
  if (api_ == nullptr) {
    return {};
  }
  char path_buffer[4096] = {0};
  if (RIME_API_AVAILABLE(api_, get_shared_data_dir_s)) {
    api_->get_shared_data_dir_s(path_buffer, sizeof(path_buffer));
    return std::string(path_buffer);
  }
  return NullSafeString(api_->get_shared_data_dir());
}

std::string RimeEngine::GetSyncDir() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (api_ == nullptr) {
    api_ = rime_get_api();
  }
  if (api_ == nullptr) {
    return {};
  }
  char path_buffer[4096] = {0};
  if (RIME_API_AVAILABLE(api_, get_sync_dir_s)) {
    api_->get_sync_dir_s(path_buffer, sizeof(path_buffer));
    return std::string(path_buffer);
  }
  return NullSafeString(api_->get_sync_dir());
}

// ---------------------------------------------------------------------------
// notifications
// ---------------------------------------------------------------------------

void RimeEngine::NotificationHandler(void* context_object,
                                     RimeSessionId session_id,
                                     const char* message_type,
                                     const char* message_value) {
  auto* engine = static_cast<RimeEngine*>(context_object);
  if (engine == nullptr) {
    return;
  }

  Notification notification;
  notification.session_id = static_cast<uint64_t>(session_id);
  notification.type = NullSafeString(message_type);
  notification.value = NullSafeString(message_value);

  // Deliberately does not take mutex_: Finalize() and JoinMaintenanceThread()
  // hold it while waiting for the maintenance thread that produces these
  // notifications.
  std::lock_guard<std::mutex> lock(engine->notification_mutex_);
  if (engine->sink_) {
    engine->sink_(notification);
    return;
  }
  // Buffer until the JS side installs a sink.
  if (engine->pending_.size() >= kMaxPendingNotifications) {
    engine->pending_.pop_front();
  }
  engine->pending_.push_back(std::move(notification));
}

void RimeEngine::SetNotificationSink(NotificationSink sink) {
  std::deque<Notification> backlog;
  {
    std::lock_guard<std::mutex> lock(notification_mutex_);
    sink_ = std::move(sink);
    backlog.swap(pending_);
  }
  // Replay anything that arrived before the sink was installed, outside the
  // lock so a slow sink cannot block librime's threads.
  for (const auto& notification : backlog) {
    if (sink_) {
      sink_(notification);
    }
  }
}

bool RimeEngine::PollNotification(Notification* notification) {
  std::lock_guard<std::mutex> lock(notification_mutex_);
  if (pending_.empty()) {
    return false;
  }
  if (notification != nullptr) {
    *notification = std::move(pending_.front());
  }
  pending_.pop_front();
  return true;
}

}  // namespace rime_ohos
