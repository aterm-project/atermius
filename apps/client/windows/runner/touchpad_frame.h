#ifndef RUNNER_TOUCHPAD_FRAME_H_
#define RUNNER_TOUCHPAD_FRAME_H_

#include <cstdint>
#include <set>
#include <vector>

struct TouchpadFrameContact {
  uint32_t id;
  double x, y;
  bool touching = true, confident = true;
};

// HID hybrid reports share a scan time; only the first has a nonzero
// contact count. Count every reported contact, including lifted fingers,
// but send only intentional live fingers to the gesture recognizer.
class TouchpadFrameAssembler {
public:
  struct Result {
    bool complete = false, cancelled = false;
    std::vector<TouchpadFrameContact> contacts;
  };

  Result Add(uint32_t count, uint32_t scan,
             const std::vector<TouchpadFrameContact> &slots) {
    if (count > 16)
      return Cancel();
    if (count > 0) {
      if (finished_ && scan == scan_)
        return {};
      Reset();
      scan_ = scan;
      expected_ = count;
      pending_ = true;
    } else if (!pending_ || scan != scan_) {
      // An orphan continuation is not a lift or a tap. Dropped reports
      // must release an app-switch modifier without creating a shortcut.
      if (!slots.empty())
        return Cancel();
      Reset();
      scan_ = scan;
      finished_ = true;
      return {true, false, {}};
    }
    for (const auto &contact : slots) {
      if (ids_.size() >= expected_)
        break;
      if (!ids_.insert(contact.id).second)
        return Cancel();
      if (contact.touching && !contact.confident)
        return Cancel();
      if (contact.touching)
        contacts_.push_back(contact);
    }
    if (ids_.size() < expected_)
      return {};
    pending_ = false;
    finished_ = true;
    return {true, false, contacts_};
  }

  void Reset() {
    pending_ = finished_ = false;
    expected_ = 0;
    ids_.clear();
    contacts_.clear();
  }

  bool pending() const { return pending_; }

private:
  Result Cancel() {
    Reset();
    return {false, true, {}};
  }
  bool pending_ = false, finished_ = false;
  uint32_t scan_ = 0, expected_ = 0;
  std::set<uint32_t> ids_;
  std::vector<TouchpadFrameContact> contacts_;
};
#endif
