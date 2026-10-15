#include "prepare_queue/prepare_queue.h"

#include <gtest/gtest.h>

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace prepare_queue;
using namespace std::chrono_literals;

namespace {

// Stands in for the platform thread: posted tasks pile up until Drain() runs
// them on the test thread.
class Inbox {
 public:
  PrepareQueue::Post poster() {
    return [this](PrepareQueue::Task t) {
      {
        std::lock_guard<std::mutex> lk(mu_);
        tasks_.push_back(std::move(t));
      }
      cv_.notify_all();
    };
  }
  bool WaitFor(size_t n) {
    std::unique_lock<std::mutex> lk(mu_);
    return cv_.wait_for(lk, 5s, [&] { return tasks_.size() >= n; });
  }
  size_t Drain() {
    std::vector<PrepareQueue::Task> ts;
    {
      std::lock_guard<std::mutex> lk(mu_);
      ts.swap(tasks_);
    }
    for (auto& t : ts) t();
    return ts.size();
  }

 private:
  std::mutex mu_;
  std::condition_variable cv_;
  std::vector<PrepareQueue::Task> tasks_;
};

// A work function that records which destinations started and blocks until Open().
class Gate {
 public:
  PrepareQueue::Work work(int32_t code = 0) {
    return [this, code](const native_path::Path&, const native_path::Path& dst, uint32_t) {
      std::unique_lock<std::mutex> lk(mu_);
      started_.push_back(dst);
      cv_.notify_all();
      cv_.wait(lk, [&] { return open_; });
      return Outcome{code, code != 0 ? "failed" : ""};
    };
  }
  void Open() {
    {
      std::lock_guard<std::mutex> lk(mu_);
      open_ = true;
    }
    cv_.notify_all();
  }
  bool WaitStarted(size_t n) {
    std::unique_lock<std::mutex> lk(mu_);
    return cv_.wait_for(lk, 5s, [&] { return started_.size() >= n; });
  }
  std::vector<native_path::Path> started() {
    std::lock_guard<std::mutex> lk(mu_);
    return started_;
  }

 private:
  std::mutex mu_;
  std::condition_variable cv_;
  bool open_ = false;
  std::vector<native_path::Path> started_;
};

}  // namespace

TEST(PrepareQueue, ResultArrivesOnlyThroughPost) {
  Inbox inbox;
  Gate gate;
  gate.Open();
  std::vector<Outcome> got;
  PrepareQueue q(gate.work(0), inbox.poster());
  q.Submit("a.mp4", "a.aipmat", 720, [&](const Outcome& o) { got.push_back(o); });
  ASSERT_TRUE(inbox.WaitFor(1));
  EXPECT_TRUE(got.empty()) << "a result ran on the worker thread instead of being posted";
  EXPECT_EQ(inbox.Drain(), 1u);
  ASSERT_EQ(got.size(), 1u);
  EXPECT_EQ(got[0].code, 0);
}

TEST(PrepareQueue, SameDestinationWhileRunningIsMerged) {
  Inbox inbox;
  Gate gate;
  std::vector<int32_t> codes;
  PrepareQueue q(gate.work(0), inbox.poster());
  q.Submit("a.mp4", "x", 720, [&](const Outcome& o) { codes.push_back(o.code); });
  ASSERT_TRUE(gate.WaitStarted(1));
  q.Submit("a.mp4", "x", 720, [&](const Outcome& o) { codes.push_back(o.code); });
  gate.Open();
  ASSERT_TRUE(inbox.WaitFor(2));
  inbox.Drain();
  EXPECT_EQ(codes, (std::vector<int32_t>{0, 0}));
  EXPECT_EQ(gate.started().size(), 1u);
}

TEST(PrepareQueue, SameDestinationWhilePendingIsMerged) {
  Inbox inbox;
  Gate gate;
  int calls = 0;
  PrepareQueue q(gate.work(0), inbox.poster());
  q.Submit("y.mp4", "y", 720, [&](const Outcome&) { ++calls; });  // occupies the worker
  ASSERT_TRUE(gate.WaitStarted(1));
  q.Submit("x.mp4", "x", 720, [&](const Outcome&) { ++calls; });
  q.Submit("x.mp4", "x", 720, [&](const Outcome&) { ++calls; });
  gate.Open();
  ASSERT_TRUE(inbox.WaitFor(3));
  inbox.Drain();
  EXPECT_EQ(calls, 3);
  EXPECT_EQ(gate.started(), (std::vector<native_path::Path>{"y", "x"}));
}

TEST(PrepareQueue, JobsRunInSubmissionOrder) {
  Inbox inbox;
  Gate gate;
  gate.Open();
  PrepareQueue q(gate.work(0), inbox.poster());
  for (const char* d : {"a", "b", "c"}) q.Submit("s", d, 720, [](const Outcome&) {});
  ASSERT_TRUE(inbox.WaitFor(3));
  inbox.Drain();
  EXPECT_EQ(gate.started(), (std::vector<native_path::Path>{"a", "b", "c"}));
}

TEST(PrepareQueue, FailureCodesAndExceptionsReachTheCaller) {
  Inbox inbox;
  std::vector<Outcome> got;
  {
    PrepareQueue q([](const native_path::Path&, const native_path::Path&, uint32_t) { return Outcome{-2, "decode failed"}; },
                   inbox.poster());
    q.Submit("s", "d1", 720, [&](const Outcome& o) { got.push_back(o); });
    ASSERT_TRUE(inbox.WaitFor(1));
  }
  {
    PrepareQueue q([](const native_path::Path&, const native_path::Path&, uint32_t) -> Outcome {
                     throw std::runtime_error("boom");
                   },
                   inbox.poster());
    q.Submit("s", "d2", 720, [&](const Outcome& o) { got.push_back(o); });
    ASSERT_TRUE(inbox.WaitFor(2));
  }
  inbox.Drain();
  ASSERT_EQ(got.size(), 2u);
  EXPECT_EQ(got[0].code, -2);
  EXPECT_EQ(got[0].error, "decode failed");
  EXPECT_EQ(got[1].code, kWorkThrew);
  EXPECT_EQ(got[1].error, "boom");
}

TEST(PrepareQueue, DestructorWaitsForTheRunningJobAndCancelsThePending) {
  Inbox inbox;
  Gate gate;
  std::vector<int32_t> codes;
  auto q = std::make_unique<PrepareQueue>(gate.work(0), inbox.poster());
  q->Submit("a", "running", 720, [&](const Outcome& o) { codes.push_back(o.code); });
  ASSERT_TRUE(gate.WaitStarted(1));
  q->Submit("b", "pending", 720, [&](const Outcome& o) { codes.push_back(o.code); });
  std::thread opener([&] {
    std::this_thread::sleep_for(100ms);
    gate.Open();
  });
  const auto t0 = std::chrono::steady_clock::now();
  q.reset();  // must block until the running job finishes
  const auto waited = std::chrono::steady_clock::now() - t0;
  opener.join();
  EXPECT_GE(waited, 80ms);
  inbox.Drain();
  EXPECT_EQ(codes, (std::vector<int32_t>{0, kCancelled}));
  EXPECT_EQ(gate.started().size(), 1u) << "the pending job must never start once teardown began";
}

TEST(PrepareQueue, PostFailureDoesNotKillTheWorker) {
  Inbox inbox;
  Gate gate;
  gate.Open();
  std::vector<Outcome> got;
  bool first_call = true;
  auto throwing_poster = [&](PrepareQueue::Task t) {
    if (first_call) {
      first_call = false;
      throw std::runtime_error("post failed");
    }
    // Forward to inbox after first call
    inbox.poster()(std::move(t));
  };
  PrepareQueue q(gate.work(0), throwing_poster);
  q.Submit("a.mp4", "a", 720, [&](const Outcome& o) { got.push_back(o); });
  q.Submit("b.mp4", "b", 720, [&](const Outcome& o) { got.push_back(o); });
  ASSERT_TRUE(inbox.WaitFor(1));
  inbox.Drain();
  // The first result (a) is lost because its post threw, but b's result arrives
  EXPECT_EQ(got.size(), 1u);
  EXPECT_EQ(got[0].code, 0);
  EXPECT_EQ(gate.started().size(), 2u) << "both a and b should have been worked on";
}
