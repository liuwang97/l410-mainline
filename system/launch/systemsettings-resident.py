#!/usr/bin/python3
# L410: systemsettings --resident (run in the systemsettings 6.7 source root).
# A resident instance starts without a window and hides its window instead of quitting when it is
# closed; a later "systemsettings" hands over through KDBusService and only shows the window again
# (about 10x faster than a cold start on the Kirin 990; docs/tuning/launch-latency.md).
import sys


def sub(path, old, new):
    s = open(path).read()
    if new in s:
        return
    if s.count(old) != 1:
        sys.exit(f"{path}: anchor not found once: {old[:60]!r}")
    open(path, "w").write(s.replace(old, new, 1))


sub("app/SettingsBase.h", "    bool queryClose() override;\n",
    """    bool queryClose() override;
    // L410: started with --resident: no window at startup, closing only hides it
    static bool residentMode;
    void showResident(bool home);
""")
sub("app/SettingsBase.h", "protected:\n    QSize sizeHint() const override;\n",
    """protected:
    QSize sizeHint() const override;
    void closeEvent(QCloseEvent *event) override;
""")

sub("app/SettingsBase.cpp", "SettingsBase::SettingsBase(SidebarMode::ApplicationMode mode,",
    """bool SettingsBase::residentMode = false;

SettingsBase::SettingsBase(SidebarMode::ApplicationMode mode,""")
sub("app/SettingsBase.cpp", "    });\n\n    show();\n}\n",
    """    });

    if (!residentMode) {
        show();
    }
}

void SettingsBase::closeEvent(QCloseEvent *event)
{
    if (!residentMode) {
        KMainWindow::closeEvent(event);
        return;
    }
    // L410: a resident instance keeps running; it only hides its window
    event->ignore();
    if (!queryClose()) {
        return;
    }
    saveAutoSaveSettings();
    hide();
}

void SettingsBase::showResident(bool home)
{
    if (home && !isVisible() && m_mode == SidebarMode::SystemSettings) {
        setStartupModule(QStringLiteral("kcm_landingpage"));
        setStartupModuleArgs(QStringList());
        reloadStartupModule();
    }
    show();
    raise();
}
""")
sub("app/SettingsBase.cpp", "#include <QScreen>\n", "#include <QCloseEvent>\n#include <QScreen>\n")

sub("app/main.cpp",
    "    parser.addOption(QCommandLineOption(QStringLiteral(\"args\"), i18n(\"Arguments for the module\"), QStringLiteral(\"arguments\")));\n\n    aboutData.setupCommandLine(&parser);\n",
    """    parser.addOption(QCommandLineOption(QStringLiteral("args"), i18n("Arguments for the module"), QStringLiteral("arguments")));
    parser.addOption(QCommandLineOption(QStringLiteral("resident"), QStringLiteral("Start without a window and keep running when the window is closed")));

    aboutData.setupCommandLine(&parser);
""")
sub("app/main.cpp", "    auto mainWindow = new SettingsBase(mode, startupModule, args);\n",
    """    if (parser.isSet(QStringLiteral("resident"))) {
        SettingsBase::residentMode = true;
        application.setQuitOnLastWindowClosed(false);
    }

    auto mainWindow = new SettingsBase(mode, startupModule, args);
""")
sub("app/main.cpp", "        if (!startupModule.isEmpty()) {\n            mainWindow->setStartupModule(startupModule);",
    """        if (SettingsBase::residentMode) {
            mainWindow->showResident(startupModule.isEmpty());
        }

        if (!startupModule.isEmpty()) {
            mainWindow->setStartupModule(startupModule);""")
print("patched")
