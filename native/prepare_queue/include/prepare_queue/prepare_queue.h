#pragma once

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace prepare_queue {

struct Outcome {
  int32_t code = 0;  // 0 ok; pet_matte_prepare's negative codes; kWorkThrew; kCancelled
  std::string error;
};

inline constexpr int32_t kWorkThrew = -99;
inline constexpr int32_t kCancelled = -100;

// Runs prepare jobs on exactly ONE worker thread -- pet_matte_last_error() is a
// process-wide string, so pet_matte_prepare must never run concurrently -- and
// hands every result back through `post`, never on the worker itself (the
// plugin's post lands on the platform thread, the only place a Flutter
// MethodResult may be answered). Jobs are keyed by destination: a Submit for a
// destination that is already queued or running only adds a waiter; the
// destination's first src and edge parameters are used (later submissions' are
// ignored).
//
// Constraints on `post`: must not run the Task synchronously/reentrantly (the
// destructor iterates jobs_ without the lock after joining the worker).
class PrepareQueue {
 public:
  using Work = std::function<Outcome(const std::wstring& src, const std::wstring& dst, uint32_t edge)>;
  using Task = std::function<void()>;
  using Post = std::function<void(Task)>;
  using Done = std::function<void(const Outcome&)>;

  PrepareQueue(Work work, Post post);
  // Lets the running job finish (joins the worker), then posts kCancelled to
  // every job that never started. `post` must still work while this runs.
  ~PrepareQueue();

  PrepareQueue(const PrepareQueue&) = delete;
  PrepareQueue& operator=(const PrepareQueue&) = delete;

  void Submit(const std::wstring& src, const std::wstring& dst, uint32_t edge, Done done);

 private:
  struct Job {
    std::wstring src;
    uint32_t edge = 0;
    std::vector<Done> waiters;
  };

  void Run();

  Work work_;
  Post post_;
  std::mutex mu_;
  std::condition_variable cv_;
  std::deque<std::wstring> order_;    // destinations in FIFO order
  std::map<std::wstring, Job> jobs_;  // queued + running, keyed by destination
  bool stopping_ = false;
  std::thread worker_;  // declared last: started once everything above exists
};

}  // namespace prepare_queue
