#include "../../apps/client/windows/runner/touchpad_frame.h"
#include <cassert>
#include <iostream>
int main() {
  TouchpadFrameAssembler a;
  using C = TouchpadFrameContact;
  // Parallel, one-contact hybrid and two-contact hybrid descriptors.
  for (uint32_t stride : {1u, 2u, 4u}) {
    a.Reset();
    for (uint32_t first = 0; first < 4; first += stride) {
      std::vector<C> contacts;
      for (uint32_t i = first; i < first + stride; ++i)
        contacts.push_back({i, .1 * i, .2});
      auto r = a.Add(first == 0 ? 4 : 0, 77, contacts);
      assert(!r.cancelled);
      assert(r.complete == (first + stride == 4));
      if (r.complete)
        assert(r.contacts.size() == 4);
    }
    assert(a.Add(0, 78, {}).complete);
  }
  a.Reset();
  assert(!a.Add(4, 1, {{1, 0, 0}, {2, 0, 0}}).complete);
  auto r = a.Add(0, 1, {{3, 0, 0, false}, {4, 0, 0}});
  assert(r.complete && r.contacts.size() == 3); // liftoffs count too
  a.Reset();
  a.Add(3, 2, {{1, 0, 0}});
  assert(a.Add(0, 3, {{2, 0, 0}}).cancelled); // missing report / wrong scan
  a.Reset();
  a.Add(3, 4, {{1, 0, 0}});
  assert(a.Add(0, 4, {{1, 0, 0}}).cancelled);              // duplicate contact
  assert(a.Add(17, 5, {}).cancelled);                      // invalid frame size
  assert(a.Add(3, 6, {{1, 0, 0, true, false}}).cancelled); // palm confidence
  a.Reset();
  r = a.Add(3, 7, {{1, 0, 0}, {2, 0, 0}, {3, 0, 0}});
  assert(r.complete && r.contacts.size() == 3);
  assert(!a.Add(3, 7, {{1, 0, 0}, {2, 0, 0}, {3, 0, 0}})
              .complete); // duplicate report
  // A lost hybrid tail must not contaminate the next scan.
  a.Reset();
  a.Add(4, 8, {{1, 0, 0}});
  r = a.Add(3, 9, {{1, 0, 0}, {2, 0, 0}, {3, 0, 0}});
  assert(r.complete && r.contacts.size() == 3);
  std::cout << "touchpad frame assembly passed\n";
}
