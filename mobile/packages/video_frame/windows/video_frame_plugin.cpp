// Первый кадр видео средствами Windows (Media Foundation) — для превью в ленте и при отправке.
// Кадр не попадает в системный кэш миниатюр: файл читается напрямую, результат — только в памяти.
#include "include/video_frame/video_frame_plugin_c_api.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr UINT kDoneMessage = WM_APP + 0x51;

template <class T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

std::wstring Utf8ToWide(const std::string& s) {
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (n <= 1) return std::wstring();
  std::wstring w(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}

// Возвращает {rgba, w, h, vw, vh, rot, duration} или пустое значение.
EncodableValue Grab(const std::wstring& path, int max_side) {
  EncodableValue out;
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    IMFAttributes* attrs = nullptr;
    IMFSourceReader* reader = nullptr;
    IMFMediaType* want = nullptr;
    IMFMediaType* cur = nullptr;
    IMFMediaType* native = nullptr;
    IMFSample* sample = nullptr;
    IMFMediaBuffer* buf = nullptr;
    do {
      if (FAILED(MFCreateAttributes(&attrs, 1))) break;
      attrs->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
      if (FAILED(MFCreateSourceReaderFromURL(path.c_str(), attrs, &reader))) break;
      reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
      reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), TRUE);

      UINT32 rot = 0;
      if (SUCCEEDED(reader->GetNativeMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, &native))) {
        native->GetUINT32(MF_MT_VIDEO_ROTATION, &rot);
      }

      if (FAILED(MFCreateMediaType(&want))) break;
      want->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
      want->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
      if (FAILED(reader->SetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), nullptr, want))) break;
      if (FAILED(reader->GetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), &cur))) break;

      UINT32 w = 0, h = 0;
      if (FAILED(MFGetAttributeSize(cur, MF_MT_FRAME_SIZE, &w, &h)) || w == 0 || h == 0) break;
      LONG stride = static_cast<LONG>(w) * 4;
      UINT32 st = 0;
      if (SUCCEEDED(cur->GetUINT32(MF_MT_DEFAULT_STRIDE, &st))) stride = static_cast<LONG>(static_cast<INT32>(st));

      LONGLONG dur = 0;
      PROPVARIANT pv;
      PropVariantInit(&pv);
      if (SUCCEEDED(reader->GetPresentationAttribute(static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION, &pv)) && pv.vt == VT_UI8) {
        dur = static_cast<LONGLONG>(pv.uhVal.QuadPart);
      }
      PropVariantClear(&pv);

      for (int i = 0; i < 30 && sample == nullptr; i++) {
        DWORD flags = 0;
        if (FAILED(reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0, nullptr, &flags, nullptr, &sample))) break;
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
      }
      if (sample == nullptr) break;
      if (FAILED(sample->ConvertToContiguousBuffer(&buf))) break;

      BYTE* data = nullptr;
      DWORD len = 0;
      if (FAILED(buf->Lock(&data, nullptr, &len))) break;
      const LONG abs_stride = stride < 0 ? -stride : stride;
      if (static_cast<size_t>(len) < static_cast<size_t>(abs_stride) * h || abs_stride < static_cast<LONG>(w) * 4) {
        buf->Unlock();
        break;
      }
      // уменьшаем и переводим BGRX → RGBA
      const double scale = (std::min)(1.0, static_cast<double>(max_side) / static_cast<double>((std::max)(w, h)));
      const int ow = (std::max)(1, static_cast<int>(w * scale));
      const int oh = (std::max)(1, static_cast<int>(h * scale));
      std::vector<uint8_t> rgba(static_cast<size_t>(ow) * oh * 4);
      for (int y = 0; y < oh; y++) {
        int sy = static_cast<int>(y / scale);
        if (sy >= static_cast<int>(h)) sy = static_cast<int>(h) - 1;
        const BYTE* row = stride < 0 ? data + static_cast<size_t>(h - 1 - sy) * abs_stride : data + static_cast<size_t>(sy) * abs_stride;
        uint8_t* dst = &rgba[static_cast<size_t>(y) * ow * 4];
        for (int x = 0; x < ow; x++) {
          int sx = static_cast<int>(x / scale);
          if (sx >= static_cast<int>(w)) sx = static_cast<int>(w) - 1;
          const BYTE* px = row + static_cast<size_t>(sx) * 4;
          dst[x * 4 + 0] = px[2];
          dst[x * 4 + 1] = px[1];
          dst[x * 4 + 2] = px[0];
          dst[x * 4 + 3] = 255;
        }
      }
      buf->Unlock();

      const bool turned = rot == 90 || rot == 270;
      out = EncodableValue(EncodableMap{
          {EncodableValue("rgba"), EncodableValue(rgba)},
          {EncodableValue("w"), EncodableValue(ow)},
          {EncodableValue("h"), EncodableValue(oh)},
          {EncodableValue("vw"), EncodableValue(static_cast<int>(turned ? h : w))},
          {EncodableValue("vh"), EncodableValue(static_cast<int>(turned ? w : h))},
          {EncodableValue("rot"), EncodableValue(static_cast<int>(rot))},
          {EncodableValue("duration"), EncodableValue(static_cast<int64_t>(dur / 10000))},
      });
    } while (false);
    SafeRelease(&buf);
    SafeRelease(&sample);
    SafeRelease(&native);
    SafeRelease(&cur);
    SafeRelease(&want);
    SafeRelease(&reader);
    SafeRelease(&attrs);
    MFShutdown();
  }
  if (SUCCEEDED(co)) CoUninitialize();
  return out;
}

class VideoFramePlugin : public flutter::Plugin {
 public:
  explicit VideoFramePlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(registrar->messenger(), "lastochka/video_frame",
                                                                       &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
    // ответ отдаём в главном потоке: фоновый поток лишь сообщает окну, что кадр готов
    delegate_ = registrar->RegisterTopLevelWindowProcDelegate([this](HWND, UINT msg, WPARAM wp, LPARAM) -> std::optional<LRESULT> {
      if (msg != kDoneMessage) return std::nullopt;
      Finish(static_cast<int>(wp));
      return 0;
    });
  }

  ~VideoFramePlugin() override { registrar_->UnregisterTopLevelWindowProcDelegate(delegate_); }

 private:
  struct Pending {
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
    EncodableValue value;
  };

  void Handle(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (call.method_name() != "frame" || args == nullptr) {
      result->NotImplemented();
      return;
    }
    std::string path;
    int max_side = 480;
    auto it = args->find(EncodableValue("path"));
    if (it != args->end()) {
      if (const auto* s = std::get_if<std::string>(&it->second)) path = *s;
    }
    it = args->find(EncodableValue("max"));
    if (it != args->end()) {
      if (const auto* m = std::get_if<int32_t>(&it->second)) max_side = *m;
    }
    HWND view = registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr;
    HWND top = view ? GetAncestor(view, GA_ROOT) : nullptr;
    if (path.empty() || top == nullptr) {
      result->Success();
      return;
    }
    int id;
    {
      std::lock_guard<std::mutex> lock(mu_);
      id = ++next_id_;
      pending_[id] = Pending{std::move(result), EncodableValue()};
    }
    std::thread([this, id, top, wpath = Utf8ToWide(path), max_side]() {
      EncodableValue v = Grab(wpath, max_side);
      {
        std::lock_guard<std::mutex> lock(mu_);
        auto p = pending_.find(id);
        if (p != pending_.end()) p->second.value = std::move(v);
      }
      PostMessage(top, kDoneMessage, static_cast<WPARAM>(id), 0);
    }).detach();
  }

  void Finish(int id) {
    Pending p;
    {
      std::lock_guard<std::mutex> lock(mu_);
      auto it = pending_.find(id);
      if (it == pending_.end()) return;
      p = std::move(it->second);
      pending_.erase(it);
    }
    if (p.value.IsNull()) {
      p.result->Success();
    } else {
      p.result->Success(p.value);
    }
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  int delegate_ = 0;
  std::mutex mu_;
  int next_id_ = 0;
  std::map<int, Pending> pending_;
};

}  // namespace

void VideoFramePluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* r = flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  r->AddPlugin(std::make_unique<VideoFramePlugin>(r));
}
