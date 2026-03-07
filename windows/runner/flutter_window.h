

class FlutterWindow : public Win32Window {
 public:
  
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  
  flutter::DartProject project_;

  
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};
