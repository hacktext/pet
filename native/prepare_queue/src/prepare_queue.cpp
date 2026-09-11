#include "prepare_queue/prepare_queue.h"

#include <exception>
#include <utility>

namespace prepare_queue {

PrepareQueue::PrepareQueue(Work work, Post post) : work_(std::move(work)), post_(std::move(post)) {
  worker_ = std::thread([this] { Run(); });
}

PrepareQueue::~PrepareQueue() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stopping_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) worker_.join();
  // The worker is gone, so jobs_ now holds only jobs that never started.
  for (auto& [dst, job] : jobs_) {
    for (auto& done : job.waiters) {
      post_([done] { done(Outcome{kCancelled, "cancelled"}); });
    }
  }
  jobs_.clear();
}

void PrepareQueue::Submit(const std::wstring& src, const std::wstring& dst, uint32_t edge, Done done) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = jobs_.find(dst);
    if (it != jobs_.end()) {
      it->second.waiters.push_back(std::move(done));
      return;
    }
    Job job;
    job.src = src;
    job.edge = edge;
    job.waiters.push_back(std::move(done));
    jobs_.emplace(dst, std::move(job));
    order_.push_back(dst);
  }
  cv_.notify_one();
}

void PrepareQueue::Run() {
  std::unique_lock<std::mutex> lk(mu_);
  while (true) {
    // stopping_ is checked between jobs only: a running prepare always finishes.
    cv_.wait(lk, [this] { return stopping_ || !order_.empty(); });
    if (stopping_) return;
    const std::wstring dst = order_.front();
    order_.pop_front();
    const std::wstring src = jobs_.at(dst).src;
    const uint32_t edge = jobs_.at(dst).edge;
    lk.unlock();

    Outcome out;
    try {
      out = work_(src, dst, edge);
    } catch (const std::exception& e) {
      out = Outcome{kWorkThrew, e.what()};
    } catch (...) {
      out = Outcome{kWorkThrew, "unknown exception"};
    }

    lk.lock();
    // Waiters that arrived while the job ran were appended to this same entry.
    std::vector<Done> waiters = std::move(jobs_.at(dst).waiters);
    jobs_.erase(dst);
    lk.unlock();
    for (auto& done : waiters) {
      post_([done, out] { done(out); });
    }
    lk.lock();
  }
}

}  // namespace prepare_queue
