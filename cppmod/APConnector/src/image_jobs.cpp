// The background job slots the map pictures run in (JobSlot in image_tools.hpp).
#include "image_tools.hpp"

#include <exception>
#include <thread>

// The slots are globals that live all session, so a detached job may keep a pointer to its slot.
auto JobSlot::start(std::function<std::string()> job) -> std::string
{
    {
        std::lock_guard<std::mutex> guard(m_lock);
        if (m_state == "busy") return "busy";
        m_state = "busy";
    }
    try
    {
        std::thread([this, job] {
            std::string err;
            try
            {
                err = job();
            }
            catch (const std::exception& e)
            {
                err = e.what();
            }
            std::lock_guard<std::mutex> guard(m_lock);
            m_state = err.empty() ? "done" : "error: " + err;
        }).detach();
    }
    catch (const std::exception& e)   // no thread could be made: else the slot would stay "busy" all session
    {
        std::lock_guard<std::mutex> guard(m_lock);
        m_state = std::string("error: could not start the job's thread: ") + e.what();
    }
    return "";
}

auto JobSlot::status() -> std::string
{
    std::lock_guard<std::mutex> guard(m_lock);
    std::string st = m_state;
    if (st != "busy") m_state.clear();
    return st;
}

namespace
{
JobSlot map_slot, chart_slot, fog_slot, territory_slot;
} // namespace

auto map_jobs() -> JobSlot& { return map_slot; }
auto chart_jobs() -> JobSlot& { return chart_slot; }
auto fog_jobs() -> JobSlot& { return fog_slot; }
auto territory_jobs() -> JobSlot& { return territory_slot; }
