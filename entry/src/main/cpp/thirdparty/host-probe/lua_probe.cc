// Runtime check that librime's Lua plugin actually executes scripts.
//
// Linking the plugin is not the same as running it: the plugin only works if its
// module is registered and the interpreter is reachable, and both of those fail
// silently at build time.  This drives a schema whose only translator is
// `lua_translator@test_lua` and looks for the candidate that the script emits.
//
// Expects <shared>/luatest.schema.yaml and <user>/rime.lua, both written by the
// caller.

#include <rime_api.h>

#include <cstdio>
#include <cstring>
#include <string>

namespace {

void PrintCandidates(RimeApi* api, RimeSessionId session, const char* label) {
  RIME_STRUCT(RimeContext, ctx);
  if (!api->get_context(session, &ctx)) {
    printf("%s: no context\n", label);
    return;
  }
  printf("%s: candidates(%d):", label, ctx.menu.num_candidates);
  for (int i = 0; i < ctx.menu.num_candidates && i < 8; ++i) {
    printf(" [%s]", ctx.menu.candidates[i].text);
  }
  printf("\n");
  api->free_context(&ctx);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <shared_data_dir> <user_data_dir>\n", argv[0]);
    return 2;
  }
  setvbuf(stdout, nullptr, _IONBF, 0);

  RimeApi* api = rime_get_api();
  if (api == nullptr) {
    fprintf(stderr, "rime_get_api() returned null\n");
    return 1;
  }

  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.distribution_name = "LuaProbe";
  traits.distribution_code_name = "luaprobe";
  traits.distribution_version = "1";
  traits.app_name = "rime.luaprobe";
  traits.min_log_level = 1;
  traits.log_dir = "";

  api->setup(&traits);
  api->initialize(&traits);
  api->start_maintenance(True);
  api->join_maintenance_thread();

  RimeSessionId session = api->create_session();
  if (session == 0) {
    fprintf(stderr, "create_session failed\n");
    return 1;
  }

  if (!api->select_schema(session, "luatest")) {
    printf("RESULT: FAIL -- schema 'luatest' could not be selected\n");
    return 1;
  }
  printf("schema selected: luatest\n");

  // "lua" is the input the script reacts to.
  for (const char* p = "lua"; *p; ++p) {
    api->process_key(session, *p, 0);
  }
  PrintCandidates(api, session, "typed 'lua'");

  RIME_STRUCT(RimeContext, ctx);
  bool found = false;
  if (api->get_context(session, &ctx)) {
    for (int i = 0; i < ctx.menu.num_candidates; ++i) {
      if (ctx.menu.candidates[i].text != nullptr &&
          strcmp(ctx.menu.candidates[i].text, "LUA_WORKS") == 0) {
        found = true;
        break;
      }
    }
    api->free_context(&ctx);
  }

  printf("RESULT: %s\n", found ? "PASS -- lua_translator ran" : "FAIL -- script did not run");

  api->destroy_session(session);
  api->finalize();
  return found ? 0 : 1;
}
