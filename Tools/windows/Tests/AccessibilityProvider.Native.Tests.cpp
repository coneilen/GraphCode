#include <windows.h>
#include <oleauto.h>
#include <UIAutomation.h>
#include <cstdio>
#include <cwchar>

extern "C" IRawElementProviderSimple *gc_uia_create(HWND hwnd);
extern "C" void gc_uia_release(IRawElementProviderSimple *provider);
extern "C" HRESULT gc_uia_update(IRawElementProviderSimple *provider, const char *status,
                                   const char **identities, const char **names,
                                   const int *parents, const int *selected,
                                   const int *eligible, const int *invokable,
                                   const int *bounds, int count, int allow_reclaim,
                                   int confirm_each_reclaim);

static int failures = 0;
static int checks = 0;

static void check(bool condition, const char *description) {
  ++checks;
  if (!condition) {
    ++failures;
    std::fprintf(stderr, "FAIL: %s\n", description);
  }
}

static IRawElementProviderFragment *child(
    IRawElementProviderFragment *parent, NavigateDirection direction) {
  IRawElementProviderFragment *result = nullptr;
  check(parent && parent->Navigate(direction, &result) == S_OK && result,
        "native UIA navigation returns the requested element");
  return result;
}

static void checkName(IRawElementProviderFragment *fragment, const wchar_t *expected) {
  IRawElementProviderSimple *simple = nullptr;
  check(fragment && fragment->QueryInterface(IID_PPV_ARGS(&simple)) == S_OK,
        "retained fragment supports the native property API");
  if (!simple) return;
  VARIANT value;
  VariantInit(&value);
  const HRESULT result = simple->GetPropertyValue(UIA_NamePropertyId, &value);
  check(result == S_OK && value.vt == VT_BSTR &&
            value.bstrVal && std::wcscmp(value.bstrVal, expected) == 0,
        "retained element exposes the expected published name");
  VariantClear(&value);
  simple->Release();
}

int main() {
  HWND hwnd = CreateWindowW(L"STATIC", L"UIA native test", WS_OVERLAPPED,
                            0, 0, 100, 100, nullptr, nullptr, nullptr, nullptr);
  check(hwnd != nullptr, "native window exists");
  if (!hwnd) return 1;

  auto *provider = gc_uia_create(hwnd);
  check(provider != nullptr, "native provider exists");
  if (!provider) return 1;
  const char *identities[] = {"worktree:test"};
  const char *names[] = {"Original"};
  const int parents[] = {3};
  const int flags[] = {0};
  check(gc_uia_update(provider, "Ready", identities, names, parents,
                      flags, flags, flags, nullptr, 1, 0, 1) == S_OK,
        "initial native publication succeeds");

  IRawElementProviderFragment *root = nullptr;
  check(provider->QueryInterface(IID_PPV_ARGS(&root)) == S_OK, "root fragment exists");
  auto *projects = child(root, NavigateDirection_FirstChild);
  auto *loops = child(projects, NavigateDirection_NextSibling);
  auto *worktrees = child(loops, NavigateDirection_NextSibling);
  auto *retained = child(worktrees, NavigateDirection_FirstChild);
  auto *graph = child(worktrees, NavigateDirection_NextSibling);
  auto *actions = child(graph, NavigateDirection_NextSibling);
  auto *status = child(actions, NavigateDirection_NextSibling);
  checkName(retained, L"Original");
  checkName(status, L"Ready");

  check(gc_uia_update(provider, "\xff", identities, names, parents,
                      flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
        "malformed UTF-8 status is rejected");
  checkName(status, L"Ready");
  const char *bad_utf8[] = {"\xff", "\xc0\xaf", "\xed\xa0\x80", "\xe2\x82"};
  for (const char *bad : bad_utf8) {
    const char *invalid_names[] = {bad};
    const char *invalid_identities[] = {bad};
    check(gc_uia_update(provider, "Changed", identities, invalid_names, parents,
                        flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
          "malformed name is rejected");
    check(gc_uia_update(provider, "Changed", invalid_identities, names, parents,
                        flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
          "malformed identity is rejected");
    checkName(retained, L"Original");
    checkName(status, L"Ready");
  }
  check(gc_uia_update(provider, "Changed", nullptr, names, parents,
                      flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
        "missing row identities are rejected without changing the tree");
  check(gc_uia_update(provider, "Changed", identities, nullptr, parents,
                      flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
        "missing row names are rejected without changing the tree");
  const char *missing_name[] = {nullptr};
  check(gc_uia_update(provider, "Changed", identities, missing_name, parents,
                      flags, flags, flags, nullptr, 1, 1, 0) == E_INVALIDARG,
        "null individual row name is rejected without changing the tree");
  check(gc_uia_update(provider, "Changed", identities, names, parents,
                      flags, flags, nullptr, nullptr, 1, 1, 0) == E_INVALIDARG,
        "missing row flag array is rejected without changing the tree");
  checkName(retained, L"Original");
  checkName(status, L"Ready");

  check(gc_uia_update(provider, "Cleared", nullptr, nullptr, nullptr,
                      nullptr, nullptr, nullptr, nullptr, 0, 0, 1) == S_OK,
        "subsequent valid empty publication succeeds");
  IRawElementProviderSimple *old_simple = nullptr;
  if (retained && retained->QueryInterface(IID_PPV_ARGS(&old_simple)) == S_OK) {
    VARIANT value;
    VariantInit(&value);
    check(old_simple->GetPropertyValue(UIA_NamePropertyId, &value) ==
              UIA_E_ELEMENTNOTAVAILABLE,
          "removed retained row is unavailable");
    VariantClear(&value);
    old_simple->Release();
  }
  checkName(status, L"Cleared");

  const char *unicode_names[] = {"Caf\xc3\xa9"};
  check(gc_uia_update(provider, "Restored", identities, unicode_names, parents,
                      flags, flags, flags, nullptr, 1, 0, 1) == S_OK,
        "valid UTF-8 remains publishable");
  auto *replacement = child(worktrees, NavigateDirection_FirstChild);
  checkName(replacement, L"Caf\u00e9");
  IRawElementProviderSimple *retired_simple = nullptr;
  if (retained && retained->QueryInterface(IID_PPV_ARGS(&retired_simple)) == S_OK) {
    VARIANT value;
    VariantInit(&value);
    check(retired_simple->GetPropertyValue(UIA_NamePropertyId, &value) ==
              UIA_E_ELEMENTNOTAVAILABLE,
          "reusing a row identity does not revive a retired provider reference");
    VariantClear(&value);
    retired_simple->Release();
  }
  if (replacement) replacement->Release();
  if (status) status->Release();
  if (actions) actions->Release();
  if (graph) graph->Release();
  if (retained) retained->Release();
  if (worktrees) worktrees->Release();
  if (loops) loops->Release();
  if (projects) projects->Release();
  if (root) root->Release();
  gc_uia_release(provider);
  DestroyWindow(hwnd);
  std::printf("Native accessibility provider: %d checks, %d failures\n", checks, failures);
  return failures || checks == 0 ? 1 : 0;
}
