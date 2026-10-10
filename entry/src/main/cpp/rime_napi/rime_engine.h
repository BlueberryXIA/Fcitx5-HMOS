// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Haochen Xia
//
/*
 * Rime engine wrapper for the HarmonyOS input method.
 *
 * Owns the single librime instance used by the process and serialises access to
 * it.  librime sessions are not thread-safe, and both the keyboard UI and the
 * input-method service may drive the engine, so every entry point here takes the
 * same mutex.
 *
 * Notifications are the one thing librime delivers from its own threads, so they
 * are guarded by a *separate* mutex.  Sharing the engine mutex would deadlock:
 * Finalize() and JoinMaintenanceThread() hold it while waiting for the
 * maintenance thread that raises those notifications.
 */

#ifndef FCITX5_OHOS_RIME_ENGINE_H_
#define FCITX5_OHOS_RIME_ENGINE_H_

#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include <rime_api.h>

namespace rime_ohos {

struct Candidate {
  std::string text;
  std::string comment;
};

struct Menu {
  int page_size = 0;
  int page_no = 0;
  bool is_last_page = false;
  int highlighted_candidate_index = 0;
  int num_candidates = 0;
  std::vector<Candidate> candidates;
  std::string select_keys;
};

struct Composition {
  int length = 0;
  int cursor_pos = 0;
  int sel_start = 0;
  int sel_end = 0;
  std::string preedit;
};

struct Context {
  bool valid = false;
  Composition composition;
  Menu menu;
  std::string commit_text_preview;
};

struct Status {
  bool valid = false;
  std::string schema_id;
  std::string schema_name;
  bool is_disabled = false;
  bool is_composing = false;
  bool is_ascii_mode = false;
  bool is_full_shape = false;
  bool is_simplified = false;
  bool is_traditional = false;
  bool is_ascii_punct = false;
};

/** One entry of the full candidate list, with its global index. */
struct CandidateListItem {
  /** Index into the whole candidate list, which is what select_candidate wants. */
  size_t index = 0;
  std::string text;
  std::string comment;
};

/**
 * One toggle declared by a schema's `switches:` block.
 *
 * The labels come straight from the schema YAML (and any *.custom.yaml patch),
 * so the settings panel is defined by the Rime configuration rather than by
 * anything hardcoded here.
 */
struct SchemaSwitch {
  /** Option name for a plain on/off switch, e.g. "ascii_mode". */
  std::string name;
  /**
   * Option names for a radio group, e.g. [zh_trad, zh_simp, zh_hk, zh_tw].
   *
   * Rime schemas spell this form with `options:` instead of `name:`; exactly one
   * of the listed options is on at a time.  Empty for a plain switch.
   */
  std::vector<std::string> options;
  /**
   * Labels indexed by state: [off, on] for a plain switch, one per option for a
   * radio group.
   */
  std::vector<std::string> states;
  /** Value the schema asks for on reset, or -1 when unspecified. */
  int reset = -1;
};

struct SchemaItem {
  std::string schema_id;
  std::string name;
};

// A deployment/schema/option notification raised by librime.
struct Notification {
  uint64_t session_id = 0;
  std::string type;
  std::string value;
};

class RimeEngine {
 public:
  static RimeEngine& Instance();

  RimeEngine(const RimeEngine&) = delete;
  RimeEngine& operator=(const RimeEngine&) = delete;

  // Point librime at its data directories.  Must be called before Initialize().
  void Configure(const std::string& shared_data_dir,
                 const std::string& user_data_dir,
                 const std::string& log_dir,
                 const std::string& app_name,
                 int min_log_level);

  // Bring librime up.  Safe to call more than once; later calls are no-ops.
  bool Initialize();

  // Tear librime down and drop all sessions.
  void Finalize();

  /**
   * Tears librime down and brings it back up with the same configuration.
   *
   * Needed after a deployment: every parsed config file is shared through
   * ConfigComponentBase::GetConfigData(), whose cache lives in the component
   * graph, so a changed schema YAML on disk is otherwise never re-read.  This is
   * finalize + setup + initialize: the teardown destroys the component graph --
   * dropping that cache -- and initialize() rebuilds it from the files.
   *
   * Call it lazily from the UI side, never from a deployment notification:
   * finalize() waits for librime's maintenance thread, which is still running
   * while it reports deployment progress.
   */
  bool Restart();

  bool IsInitialized();

  // Run the deployer on the calling thread and only return when it is done.
  // `full_check` is ignored: librime's deploy() has no light mode and always
  // rebuilds the whole workspace.  Prefer StartMaintenance() from the UI.
  bool Deploy(bool full_check);

  // Run the deployer on librime's maintenance thread, so the UI can appear
  // immediately and follow progress through notifications.  With `full_check`
  // false librime first looks for modified files and skips the rebuild when
  // nothing changed.
  bool StartMaintenance(bool full_check);
  bool IsMaintenanceMode();
  void JoinMaintenanceThread();

  // --- session management -----------------------------------------------
  uint64_t CreateSession();
  bool DestroySession(uint64_t session_id);
  bool FindSession(uint64_t session_id);
  void DestroyAllSessions();

  // --- input ------------------------------------------------------------
  bool ProcessKey(uint64_t session_id, int keysym, int modifiers);
  bool CommitComposition(uint64_t session_id);
  void ClearComposition(uint64_t session_id);
  bool SetInput(uint64_t session_id, const std::string& input);

  // --- output -----------------------------------------------------------
  Context GetContext(uint64_t session_id);

  /**
   * Every candidate for the session, not just the current page.
   *
   * The candidate bar paginates on the UI side so that the number of candidates
   * per page can follow how long they are; librime's own menu page size is
   * unrelated to that.  Menu::GetCandidateAt() pulls from the translation on
   * demand, so this really does walk the whole list.
   */
  std::vector<CandidateListItem> GetCandidateList(uint64_t session_id);
  // Returns true and fills *text when librime has commit text pending.
  bool GetCommit(uint64_t session_id, std::string* text);
  Status GetStatus(uint64_t session_id);

  bool SelectCandidate(uint64_t session_id, size_t index);
  bool DeleteCandidate(uint64_t session_id, size_t index);
  bool HighlightCandidate(uint64_t session_id, size_t index);
  bool ChangePage(uint64_t session_id, bool backward);

  // --- options / schemas ------------------------------------------------
  void SetOption(uint64_t session_id, const std::string& option, bool value);
  bool GetOption(uint64_t session_id, const std::string& option);
  std::vector<SchemaItem> GetSchemaList();

  /** Toggles declared by `switches:` in the given schema (patches applied). */
  std::vector<SchemaSwitch> GetSchemaSwitches(const std::string& schema_id);

  /**
   * Whether a named engine component is registered.
   *
   * Plugins register their components at start-up, so this is how the UI can
   * tell whether Lua scripting ("lua_translator") or grammar models ("grammar")
   * are actually available, rather than inferring it from a schema silently
   * doing nothing.
   */
  bool HasComponent(const std::string& name);

  /**
   * The `grammar/language` the session's schema declares, or "".
   *
   * The grammar plugin loads `<language>.gram` from the data directories, so
   * this is the name to look for on disk.  Reporting it turns "grammar is not
   * working" into "the file is missing" or "the file is there".
   */
  std::string GetGrammarLanguage(uint64_t session_id);
  std::string GetCurrentSchema(uint64_t session_id);
  bool SelectSchema(uint64_t session_id, const std::string& schema_id);

  // --- misc -------------------------------------------------------------
  std::string GetVersion();
  std::string GetUserDataDir();
  std::string GetSharedDataDir();
  std::string GetSyncDir();

  // Invoked on librime's own threads when it raises a notification, and on the
  // caller's thread for the backlog SetNotificationSink() replays.
  using NotificationSink = std::function<void(const Notification&)>;
  void SetNotificationSink(NotificationSink sink);

  // Pop the oldest queued notification; false when the queue is empty.
  // Notifications are buffered while no sink is installed, so nothing is lost
  // before the JS side is ready; once a sink is set, new notifications go
  // straight to it and this queue stays empty.
  bool PollNotification(Notification* notification);

 private:
  RimeEngine();
  ~RimeEngine();

  static void NotificationHandler(void* context_object,
                                  RimeSessionId session_id,
                                  const char* message_type,
                                  const char* message_value);

  RimeApi* api_ = nullptr;

  // Guards every librime call except the notification path.
  mutable std::mutex mutex_;

  bool configured_ = false;
  bool initialized_ = false;

  std::string shared_data_dir_;
  std::string user_data_dir_;
  std::string log_dir_;
  std::string app_name_;
  int min_log_level_ = 0;

  // Keeps the strings RimeTraits points at alive for librime's lifetime.
  // std::deque never invalidates references to existing elements, so the
  // c_str() pointers stored in traits_ stay valid as we add more.
  std::deque<std::string> traits_strings_;
  RimeTraits traits_{};
  bool traits_ready_ = false;

  std::mutex notification_mutex_;
  NotificationSink sink_;
  std::deque<Notification> pending_;
  static constexpr size_t kMaxPendingNotifications = 256;
};

}  // namespace rime_ohos

#endif  // FCITX5_OHOS_RIME_ENGINE_H_
