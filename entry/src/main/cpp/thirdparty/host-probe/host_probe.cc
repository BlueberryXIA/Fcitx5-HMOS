// Host-side probe for the Rime switch behaviour the keyboard's settings panel
// relies on.
//
// It answers three questions against a real librime:
//   1. do set_option()/get_option() round-trip for schema-declared options?
//   2. what does the `switches:` block of the bundled schema actually contain?
//   3. does turning on zh_simp change the committed text to Simplified?
//
// Build: see scripts/build_host_probe.sh (or the command recorded in the
// session). Run with the shared data dir and a writable user dir.

#include <rime/registry.h>
#include <rime_api.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

const char* kOptions[] = {
    "zh_trad", "zh_simp", "zh_hk", "zh_tw",
    "ascii_mode", "full_shape", "ascii_punct",
};

void DumpOptions(RimeApi* api, RimeSessionId session, const char* when) {
  printf("--- options %s ---\n", when);
  for (const char* name : kOptions) {
    printf("    %-12s = %d\n", name, api->get_option(session, name));
  }
}

// Prints the schema's switches exactly the way the keyboard's native layer
// enumerates them.
void DumpSwitches(RimeApi* api, RimeSessionId session) {
  char schema_id[256] = {0};
  if (!api->get_current_schema(session, schema_id, sizeof(schema_id))) {
    printf("!! no current schema\n");
    return;
  }
  printf("--- switches of '%s' ---\n", schema_id);
  // Printed before anything else: the grammar plugin only constructs itself when
  // grammar/language is present, so its absence is the first thing to rule out.
  {
    RimeConfig probe_config = {0};
    if (api->schema_open(schema_id, &probe_config)) {
      const char* lang = api->config_get_cstring(&probe_config, "grammar/language");
      printf("    grammar/language = '%s'\n", lang ? lang : "(unset)");
      api->config_close(&probe_config);
    }
  }

  RimeConfig config = {0};
  if (!api->schema_open(schema_id, &config)) {
    printf("!! schema_open failed\n");
    return;
  }

  RimeConfigIterator it = {0};
  if (api->config_begin_list(&it, &config, "switches")) {
    while (api->config_next(&it)) {
      const std::string base = it.path ? it.path : "";
      const char* name = api->config_get_cstring(&config, (base + "/name").c_str());
      printf("    switch %s : name='%s' options=[", base.c_str(),
             name ? name : "");
      const size_t n = api->config_list_size(&config, (base + "/options").c_str());
      for (size_t i = 0; i < n; ++i) {
        const char* o = api->config_get_cstring(
            &config, (base + "/options/@" + std::to_string(i)).c_str());
        printf("%s%s", i ? "," : "", o ? o : "?");
      }
      printf("] states=[");
      const size_t s = api->config_list_size(&config, (base + "/states").c_str());
      for (size_t i = 0; i < s; ++i) {
        const char* v = api->config_get_cstring(
            &config, (base + "/states/@" + std::to_string(i)).c_str());
        printf("%s%s", i ? "," : "", v ? v : "?");
      }
      printf("]\n");
    }
    api->config_end(&it);
  }
  api->config_close(&config);
}

// Types "nihao", reports the candidates, takes the first one and reports what
// was committed.  The candidate text is the evidence that matters here: with a
// working Simplified conversion the first candidate is 你好 rather than 你好 in
// Traditional form.
std::string TypeAndCommit(RimeApi* api, RimeSessionId session, const char* letters) {
  for (const char* p = letters; *p; ++p) {
    api->process_key(session, *p, 0);
  }

  RIME_STRUCT(RimeContext, ctx);
  if (api->get_context(session, &ctx)) {
    printf("    candidates(%d):", ctx.menu.num_candidates);
    for (int i = 0; i < ctx.menu.num_candidates && i < 6; ++i) {
      printf(" [%s]", ctx.menu.candidates[i].text);
    }
    printf("\n");
    api->free_context(&ctx);
  } else {
    printf("    no context\n");
  }

  api->select_candidate(session, 0);

  RIME_STRUCT(RimeCommit, commit);
  std::string text;
  if (api->get_commit(session, &commit)) {
    if (commit.text) {
      text = commit.text;
    }
    api->free_commit(&commit);
  }
  // Clear anything left over so the next round starts clean.
  api->clear_composition(session);
  return text;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <shared_data_dir> <user_data_dir> [input]\n", argv[0]);
    return 2;
  }

  // Unbuffered: a crash must not swallow the progress markers.
  setvbuf(stdout, nullptr, _IONBF, 0);

  // The syllables to type.  A longer input is where a grammar model shows up:
  // short inputs are decided by dictionary weight alone.
  const char* input = argc > 3 ? argv[3] : "nihao";

  printf("step 1: rime_get_api\n");
  RimeApi* api = rime_get_api();
  printf("step 2: api=%p\n", static_cast<void*>(api));
  if (api == nullptr) {
    fprintf(stderr, "rime_get_api() returned null\n");
    return 1;
  }

  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.distribution_name = "Probe";
  traits.distribution_code_name = "probe";
  traits.distribution_version = "1";
  traits.app_name = "rime.probe";
  traits.min_log_level = 0;
  traits.log_dir = "";

  printf("step 3: setup\n");
  api->setup(&traits);
  printf("step 4: initialize\n");
  api->initialize(&traits);

  printf("step 5: deploy\n");
  api->start_maintenance(True);
  api->join_maintenance_thread();
  printf("deploy done\n\n");

  // Definitive plugin check: a merged plugin only works if its module was loaded
  // and its component registered, and neither is visible from the config alone.
  {
    rime::Registry& registry = rime::Registry::instance();
    printf("component check: grammar=%d lua_translator=%d lua_filter=%d simplifier=%d\n",
           registry.Find("grammar") != nullptr,
           registry.Find("lua_translator") != nullptr,
           registry.Find("lua_filter") != nullptr,
           registry.Find("simplifier") != nullptr);
  }

  printf("step 6: create session\n");
  // One fresh session per variant: select_candidate() leaves a composition
  // behind, and a clean session keeps each measurement independent.
  const char* radio[] = {"zh_trad", "zh_simp", "zh_hk", "zh_tw"};
  for (int target = 0; target < 4; ++target) {
    RimeSessionId session = api->create_session();
    if (session == 0) {
      fprintf(stderr, "create_session failed\n");
      return 1;
    }

    printf("======== %s ========\n", radio[target]);
    if (target == 0) {
      DumpSwitches(api, session);
      printf("\n");
      DumpOptions(api, session, "as created");
    }

    for (int i = 0; i < 4; ++i) {
      api->set_option(session, radio[i], i == target ? True : False);
    }
    DumpOptions(api, session, "after selecting");

    const std::string committed = TypeAndCommit(api, session, input);
    printf("    -> committed: %s\n\n", committed.c_str());

    api->destroy_session(session);
  }

  api->finalize();
  return 0;
}
