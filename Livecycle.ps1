Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ── PATHS ────────────────────────────────────────────────────
$ScriptPath    = "$env:APPDATA\Livecycle\Set-LivelyWallpaper.ps1"
$LivelyExe     = ""  # Will be detected at runtime
$ConfigFile    = "$env:APPDATA\Livecycle\config.json"
$StateFile     = "$env:TEMP\lively_current_wallpaper.txt"
$WallpaperDir  = "$env:APPDATA\Livecycle\wallpapers"

# Ensure wallpaper dir exists
if (-not (Test-Path $WallpaperDir)) { New-Item -ItemType Directory -Path $WallpaperDir | Out-Null }

# -- DETECT LIVELY --------------------------------------------
function Find-LivelyExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Lively Wallpaper\Lively.exe"),
        (Join-Path $env:PROGRAMFILES "Lively Wallpaper\Lively.exe")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c -ErrorAction SilentlyContinue)) { return $c }
    }
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($rp in $regPaths) {
        if ($rp -and (Test-Path $rp -ErrorAction SilentlyContinue)) {
            Get-ChildItem $rp -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $loc = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).InstallLocation
                    if ($loc) {
                        $loc = $loc.Trim().Trim('"').Trim("'")
                        if ($loc.Length -gt 3 -and $loc -match "^[A-Za-z]:\") {
                            $candidate = Join-Path $loc "Lively.exe"
                            if (Test-Path $candidate -ErrorAction SilentlyContinue) {
                                return $candidate
                            }
                        }
                    }
                } catch {}
            }
        }
    }

    # Last resort - search common install folders on all available drives
    $drives = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root
    foreach ($drive in $drives) {
        $searchPaths = @(
            "${drive}Program Files\Lively Wallpaper\Lively.exe",
            "${drive}Program Files (x86)\Lively Wallpaper\Lively.exe",
            "${drive}Apps\Lively Wallpaper\Lively.exe",
            "${drive}Lively Wallpaper\Lively.exe"
        )
        foreach ($p in $searchPaths) {
            if (Test-Path $p -ErrorAction SilentlyContinue) { return $p }
        }
    }
    return $null
}

$detectedLively = Find-LivelyExe
if ($detectedLively) { $LivelyExe = $detectedLively }
$livelyInstalled = ($null -ne $detectedLively)

# ── LOAD/SAVE CONFIG ─────────────────────────────────────────
function Load-Config {
    if (Test-Path $ConfigFile) {
        try { return Get-Content $ConfigFile | ConvertFrom-Json } catch {}
    }
    return $null
}

function Save-Config($cfg) {
    $dir = Split-Path $ConfigFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $cfg | ConvertTo-Json -Depth 5 | Out-File $ConfigFile -Encoding UTF8
}

$config   = Load-Config
$firstRun = (-not $config -or -not $config.SetupDone)

# ── LOAD WALLPAPER LIBRARY ───────────────────────────────────
# Library = all files in our managed wallpapers folder
$wallpaperLibrary = [System.Collections.ObjectModel.ObservableCollection[PSCustomObject]]::new()

function Reload-Library {
    $wallpaperLibrary.Clear()
    $exts = @("*.mp4","*.gif","*.jpg","*.jpeg","*.png","*.webm","*.avi","*.mkv")
    foreach ($ext in $exts) {
        Get-ChildItem $WallpaperDir -Filter $ext -ErrorAction SilentlyContinue | ForEach-Object {
            $wallpaperLibrary.Add([PSCustomObject]@{
                Title = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                Path  = $_.FullName
                Ext   = $_.Extension.ToUpper().TrimStart(".")
                Size  = "$([math]::Round($_.Length / 1MB, 1)) MB"
            })
        }
    }
}
Reload-Library

# ── CLEAN LIVELY LIBRARY ─────────────────────────────────────
# For each filename in our library, find all Lively entries with that filename
# and remove all but the first (oldest) one
function Clean-LivelyLibrary {
    $livelyLibPaths = @(
        (Join-Path $env:LOCALAPPDATA "Lively Wallpaper\Library\SaveData\wptmp"),
        (Join-Path $env:LOCALAPPDATA "Lively Wallpaper\Library\wallpapers")
    )
    foreach ($libPath in $livelyLibPaths) {
        if (-not (Test-Path $libPath -ErrorAction SilentlyContinue)) { continue }
        # Group folders by the filename inside them
        $groups = @{}
        Get-ChildItem $libPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $folder = $_
            Get-ChildItem $folder.FullName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match "^\.(mp4|gif|jpg|jpeg|png|webm|avi|mkv)$" } |
                ForEach-Object {
                    $key = $_.Name.ToLower()
                    if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
                    $groups[$key] += $folder
                }
        }
        # For any filename with more than one folder, delete all but the first
        foreach ($key in $groups.Keys) {
            $dupes = $groups[$key]
            if ($dupes.Count -gt 1) {
                $sorted = $dupes | Sort-Object CreationTime
                for ($i = 1; $i -lt $sorted.Count; $i++) {
                    Remove-Item $sorted[$i].FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# If library is empty, clear stale state and config to avoid showing misleading data
if ($wallpaperLibrary.Count -eq 0) {
    Remove-Item $StateFile -ErrorAction SilentlyContinue
}

# ── LOAD EXISTING AUTOMATION CONFIG ──────────────────────────
$currentMode = if ($config -and $config.Mode) { $config.Mode } else { "time" }
$cfgLat  = if ($config -and $config.Lat) { $config.Lat } else { "55.8642" }
$cfgLon  = if ($config -and $config.Lon) { $config.Lon } else { "-4.2518" }
$cfgWeather = @{ Clear=""; Cloudy=""; Rainy=""; Snowy=""; Stormy=""; Foggy="" }

# Load weather from config
if ($config -and $config.Weather) {
    foreach ($w in @("Clear","Cloudy","Rainy","Snowy","Stormy","Foggy")) {
        $v = $config.Weather.$w
        if ($v) { $cfgWeather[$w] = $v }
    }
}

# ── TIME SLOTS ────────────────────────────────────────────────
$timeSlots = [System.Collections.ObjectModel.ObservableCollection[PSCustomObject]]::new()

function Get-WallpaperName($path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return "(not set)" }
    $match = $wallpaperLibrary | Where-Object { $_.Path -eq $path } | Select-Object -First 1
    if ($match) { return $match.Title }
    return [System.IO.Path]::GetFileNameWithoutExtension($path)
}

$defaultSlots = @(
    @{ Label="Morning";   Start="06:00"; Path="" },
    @{ Label="Afternoon"; Start="12:00"; Path="" },
    @{ Label="Evening";   Start="18:00"; Path="" },
    @{ Label="Night";     Start="22:00"; Path="" }
)

# Load slots from config first, fall back to defaults
if ($config -and $config.Slots -and $config.Slots.Count -gt 0) {
    foreach ($s in $config.Slots) {
        $p = if ($s.WallpaperPath) { $s.WallpaperPath } else { "" }
        $timeSlots.Add([PSCustomObject]@{
            Label=$s.Label; Start=$s.Start
            WallpaperPath=$p; WallpaperName=(Get-WallpaperName $p)
        })
    }
} else {
    foreach ($ds in $defaultSlots) {
        $timeSlots.Add([PSCustomObject]@{ Label=$ds.Label; Start=$ds.Start; WallpaperPath=""; WallpaperName="(not set)" })
    }
}

# ── XAML ─────────────────────────────────────────────────────
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Livecycle"
    Width="900" Height="640"
    WindowStartupLocation="CenterScreen"
    Background="Transparent"
    FontFamily="Segoe UI"
    WindowStyle="None"
    AllowsTransparency="True"
    ResizeMode="CanMinimize"
    AllowDrop="True">

  <Window.Resources>

    <Style x:Key="NavBtn" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#9090A8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="16,10"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="8"
                    Padding="{TemplateBinding Padding}" Margin="0,1">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#F0F0F8"/>
                <Setter Property="Foreground" Value="#5B4FE8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavBtnActive" TargetType="Button">
      <Setter Property="Background" Value="#EEEEFF"/>
      <Setter Property="Foreground" Value="#5B4FE8"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="16,10"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="8"
                    Padding="{TemplateBinding Padding}" Margin="0,1">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#555577"/>
      <Setter Property="BorderBrush" Value="#E0E0EA"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#F0F0FF"/>
                <Setter Property="BorderBrush" Value="#AAAADD"/>
                <Setter Property="Foreground" Value="#4444AA"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerBtn" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#CCAAAA"/>
      <Setter Property="BorderBrush" Value="#F0E0E0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#FFF0F0"/>
                <Setter Property="BorderBrush" Value="#FFAAAA"/>
                <Setter Property="Foreground" Value="#CC4444"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#5B4FE8"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="22,9"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#6B5FF8"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter Property="Background" Value="#4B3FD8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#222233"/>
      <Setter Property="CaretBrush" Value="#5B4FE8"/>
      <Setter Property="BorderBrush" Value="#E0E0EA"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="SelectionBrush" Value="#5B4FE8"/>
    </Style>

  </Window.Resources>

  <Border Background="#F4F5F7" CornerRadius="12">
    <Border.Effect>
      <DropShadowEffect Color="#AAAACC" BlurRadius="24" ShadowDepth="4" Opacity="0.2"/>
    </Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="200"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Sidebar -->
      <Border Grid.Column="0" Background="White" CornerRadius="12,0,0,12"
              BorderBrush="#EEEEEF" BorderThickness="0,0,1,0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="60"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <Border Grid.Row="0" x:Name="TitleBar" Cursor="SizeAll"
                  BorderBrush="#F0F0F5" BorderThickness="0,0,0,1">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
              <Ellipse Width="10" Height="10" Fill="#5B4FE8" Margin="0,0,8,0"/>
              <StackPanel>
                <TextBlock Text="Livecycle" Foreground="#5B4FE8" FontSize="11" FontFamily="Segoe UI Semibold"/>
                <TextBlock Text="Automated Wallpaper Manager" Foreground="#AAAABD" FontSize="10"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <StackPanel Grid.Row="1" Margin="10,12,10,0">
            <Button x:Name="NavHome" Style="{StaticResource NavBtnActive}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x2302;  " FontSize="14" VerticalAlignment="Center"/>
                <TextBlock Text="Home" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavLibrary" Style="{StaticResource NavBtn}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x25A6;  " FontSize="13" VerticalAlignment="Center"/>
                <TextBlock Text="Library" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavTime" Style="{StaticResource NavBtn}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x23F0;  " FontSize="13" VerticalAlignment="Center"/>
                <TextBlock Text="Time of Day" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavWeather" Style="{StaticResource NavBtn}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x2601;  " FontSize="13" VerticalAlignment="Center"/>
                <TextBlock Text="Weather" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="NavSettings" Style="{StaticResource NavBtn}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x2699;  " FontSize="13" VerticalAlignment="Center"/>
                <TextBlock Text="Settings" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>

          </StackPanel>

          <StackPanel Grid.Row="2" Margin="10,0,10,12" VerticalAlignment="Bottom">
            <Button x:Name="BtnMinimize" Style="{StaticResource NavBtn}" Margin="0,0,0,2">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x2013;  " FontSize="14" VerticalAlignment="Center"/>
                <TextBlock Text="Minimise" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnClose" Style="{StaticResource NavBtn}" Margin="0,0,0,8">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#x2715;  " FontSize="11" VerticalAlignment="Center"/>
                <TextBlock Text="Close" VerticalAlignment="Center"/>
              </StackPanel>
            </Button>
            <TextBlock Text="Created by Ben Parry" Foreground="#CCCCDD"
                       FontSize="9" FontFamily="Segoe UI" Margin="6,0,0,0"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Main content -->
      <Grid Grid.Column="1">

        <!-- ONBOARDING -->
        <ScrollViewer x:Name="PageOnboarding" VerticalScrollBarVisibility="Auto">
          <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center"
                      MaxWidth="500" Margin="40">
            <TextBlock Text="Welcome" Foreground="#1A1A2E" FontSize="26"
                       FontFamily="Segoe UI Light" TextAlignment="Center" Margin="0,0,0,8"/>
            <TextBlock Text="Add your first wallpapers to get started. You can import video and image files directly."
                       Foreground="#AAAABD" FontSize="13" TextAlignment="Center"
                       TextWrapping="Wrap" Margin="0,0,0,16"/>

            <!-- Lively missing warning on onboarding -->
            <Border x:Name="BannerOnboardLively" Background="#FFF8F0" CornerRadius="10"
                    BorderBrush="#FFD8AA" BorderThickness="1" Padding="16,12"
                    Margin="0,0,0,16" Visibility="Collapsed">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="LIVELY NOT FOUND" Foreground="#CC7700" FontSize="9"
                             FontFamily="Segoe UI Semibold" Margin="0,0,0,4"/>
                  <TextBlock Text="Lively Wallpaper must be installed before you can use this app. Download and install it first, then come back."
                             Foreground="#885500" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
                  <Button x:Name="BtnOnboardCheckLively" Content="Check Again"
                          Style="{StaticResource GhostBtn}" Padding="12,8" Margin="0,0,8,0"/>
                  <Button x:Name="BtnOnboardDownloadLively" Content="Download Lively"
                          Background="#FF9900" Foreground="White" BorderThickness="0"
                          Padding="14,8" Cursor="Hand" FontSize="12" FontFamily="Segoe UI Semibold">
                    <Button.Template>
                      <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="6"
                                Padding="{TemplateBinding Padding}">
                          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="Background" Value="#FFAA22"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Button.Template>
                  </Button>
                </StackPanel>
              </Grid>
            </Border>

            <TextBlock x:Name="DropZone" Visibility="Collapsed"/>

            <Button x:Name="BtnBrowseFiles" Content="Browse for files"
                    Style="{StaticResource GhostBtn}"
                    HorizontalAlignment="Center" Padding="24,10"/>

            <TextBlock x:Name="TxtOnboardStatus" Text="" Foreground="#5B4FE8"
                       FontSize="12" HorizontalAlignment="Center"
                       Margin="0,16,0,0" TextWrapping="Wrap" TextAlignment="Center"/>

            <Button x:Name="BtnSkipOnboard" Content="Skip for now"
                    Style="{StaticResource GhostBtn}"
                    HorizontalAlignment="Center" Margin="0,12,0,0"
                    Padding="16,7" Foreground="#AAAABD"/>
          </StackPanel>
        </ScrollViewer>

        <!-- HOME -->
        <ScrollViewer x:Name="PageHome" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,28,32,24">
            <TextBlock Text="Home" Foreground="#1A1A2E" FontSize="22"
                       FontFamily="Segoe UI Light" Margin="0,0,0,4"/>
            <TextBlock Text="Current status and quick overview"
                       Foreground="#AAAABD" FontSize="12" Margin="0,0,0,24"/>
            <Grid Margin="0,0,0,16">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Grid.Column="0" Background="White" CornerRadius="10"
                      BorderBrush="#E8E8F0" BorderThickness="1" Padding="18,14">
                <Border.Effect>
                  <DropShadowEffect Color="#CCCCDD" BlurRadius="10" ShadowDepth="1" Opacity="0.2"/>
                </Border.Effect>
                <StackPanel>
                  <TextBlock Text="CURRENT WALLPAPER" Foreground="#AAAABD"
                             FontSize="9" FontFamily="Segoe UI Semibold" Margin="0,0,0,8"/>
                  <TextBlock x:Name="TxtCurrentWallpaper" Text="--"
                             Foreground="#1A1A2E" FontSize="13" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="2" Background="White" CornerRadius="10"
                      BorderBrush="#E8E8F0" BorderThickness="1" Padding="18,14">
                <Border.Effect>
                  <DropShadowEffect Color="#CCCCDD" BlurRadius="10" ShadowDepth="1" Opacity="0.2"/>
                </Border.Effect>
                <StackPanel>
                  <TextBlock Text="MODE" Foreground="#AAAABD"
                             FontSize="9" FontFamily="Segoe UI Semibold" Margin="0,0,0,8"/>
                  <TextBlock x:Name="TxtCurrentMode" Text="--"
                             Foreground="#1A1A2E" FontSize="13"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="4" Background="White" CornerRadius="10"
                      BorderBrush="#E8E8F0" BorderThickness="1" Padding="18,14">
                <Border.Effect>
                  <DropShadowEffect Color="#CCCCDD" BlurRadius="10" ShadowDepth="1" Opacity="0.2"/>
                </Border.Effect>
                <StackPanel>
                  <TextBlock Text="NEXT CHANGE" Foreground="#AAAABD"
                             FontSize="9" FontFamily="Segoe UI Semibold" Margin="0,0,0,8"/>
                  <TextBlock x:Name="TxtNextChange" Text="--"
                             Foreground="#1A1A2E" FontSize="13"/>
                </StackPanel>
              </Border>
            </Grid>
            <Border Background="White" CornerRadius="10" BorderBrush="#E8E8F0"
                    BorderThickness="1" Padding="18,14" Margin="0,0,0,16">
              <Border.Effect>
                <DropShadowEffect Color="#CCCCDD" BlurRadius="10" ShadowDepth="1" Opacity="0.2"/>
              </Border.Effect>
              <StackPanel>
                <TextBlock Text="LIBRARY" Foreground="#AAAABD" FontSize="9"
                           FontFamily="Segoe UI Semibold" Margin="0,0,0,8"/>
                <TextBlock x:Name="TxtLibrarySummary" Text="No wallpapers imported yet."
                           Foreground="#555570" FontSize="12" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <!-- Lively missing banner -->
            <Border x:Name="BannerLivelyMissing" Background="#FFF8F0" CornerRadius="10"
                    BorderBrush="#FFD8AA" BorderThickness="1" Padding="18,14"
                    Margin="0,0,0,12" Visibility="Collapsed">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="LIVELY NOT FOUND" Foreground="#CC7700" FontSize="9"
                             FontFamily="Segoe UI Semibold" Margin="0,0,0,6"/>
                  <TextBlock Text="Lively Wallpaper is required to display wallpapers. Download and install it to get started."
                             Foreground="#885500" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
                  <Button x:Name="BtnCheckLively" Content="Check Again"
                          Style="{StaticResource GhostBtn}" Padding="12,8" Margin="0,0,8,0"/>
                  <Button x:Name="BtnDownloadLively" Content="Download Lively"
                          Background="#FF9900" Foreground="White" BorderThickness="0"
                          Padding="14,8" Cursor="Hand" FontSize="12" FontFamily="Segoe UI Semibold">
                    <Button.Template>
                      <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="6"
                                Padding="{TemplateBinding Padding}">
                          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="Background" Value="#FFAA22"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Button.Template>
                  </Button>
                </StackPanel>
              </Grid>
            </Border>

            <!-- Automation setup banner -->
            <Border x:Name="BannerSetupAutomation" Background="#F0F8FF" CornerRadius="10"
                    BorderBrush="#AACCFF" BorderThickness="1" Padding="18,14"
                    Margin="0,0,0,16" Visibility="Collapsed">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="AUTOMATION NOT SET UP" Foreground="#2255AA" FontSize="9"
                             FontFamily="Segoe UI Semibold" Margin="0,0,0,6"/>
                  <TextBlock Text="Set up the scheduler so your wallpaper changes automatically at the right times."
                             Foreground="#334466" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
                <Button x:Name="BtnSetupAutomation" Content="Set up automation"
                        Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center"
                        Style="{StaticResource PrimaryBtn}" Padding="14,8"/>
              </Grid>
            </Border>

            <!-- No buttons on home page -->
            <StackPanel Visibility="Collapsed">
              <Button x:Name="BtnTestHome"/>
              <Button x:Name="BtnSaveHome"/>
            </StackPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- LIBRARY -->
        <Grid x:Name="PageLibrary" Visibility="Collapsed">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <StackPanel Grid.Row="0" Margin="32,28,32,16">
            <TextBlock Text="Library" Foreground="#1A1A2E" FontSize="22"
                       FontFamily="Segoe UI Light" Margin="0,0,0,4"/>
            <TextBlock Text="Your imported wallpapers" Foreground="#AAAABD"
                       FontSize="12" Margin="0,0,0,0"/>
          </StackPanel>

          <ScrollViewer Grid.Row="1" Margin="32,0,32,0" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <!-- Drop zone banner -->
              <Grid x:Name="LibDropZone" Margin="0,0,0,12" HorizontalAlignment="Right">
                <Button x:Name="BtnImportFiles" Content="Browse Files"
                        Style="{StaticResource GhostBtn}" Padding="14,6"/>
              </Grid>

              <!-- Library list -->
              <ItemsControl x:Name="LibraryList">
                <ItemsControl.ItemTemplate>
                  <DataTemplate>
                    <Border Background="White" CornerRadius="8" BorderBrush="#EEEEF5"
                            BorderThickness="1" Padding="16,12" Margin="0,0,0,6">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="36"/>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="60"/>
                          <ColumnDefinition Width="40"/>
                          <ColumnDefinition Width="60"/>
                          <ColumnDefinition Width="64"/>
                          <ColumnDefinition Width="32"/>
                        </Grid.ColumnDefinitions>
                        <!-- Type badge -->
                        <Border Grid.Column="0" Background="#F0EEFF" CornerRadius="4"
                                Width="32" Height="22" HorizontalAlignment="Left">
                          <TextBlock Text="{Binding Ext}" Foreground="#5B4FE8"
                                     FontSize="8" FontFamily="Segoe UI Semibold"
                                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <!-- Title -->
                        <TextBlock Grid.Column="1" Text="{Binding Title}"
                                   Foreground="#222233" FontSize="13"
                                   VerticalAlignment="Center" Margin="10,0,8,0"
                                   TextTrimming="CharacterEllipsis"/>
                        <!-- Size -->
                        <TextBlock Grid.Column="2" Text="{Binding Size}"
                                   Foreground="#AAAABD" FontSize="11"
                                   VerticalAlignment="Center" HorizontalAlignment="Right"
                                   Margin="0,0,8,0"/>
                        <!-- Set button -->
                        <Button Grid.Column="3" Content="Set" Tag="{Binding}"
                                x:Name="BtnSetWp" Style="{StaticResource GhostBtn}"
                                Padding="6,4" FontSize="10" VerticalAlignment="Center"/>
                        <!-- Preview button -->
                        <Button Grid.Column="4" Content="Preview" Tag="{Binding}"
                                x:Name="BtnPreview" Style="{StaticResource GhostBtn}"
                                Padding="6,4" FontSize="10" VerticalAlignment="Center"
                                Margin="4,0,0,0"/>
                        <!-- Rename button -->
                        <Button Grid.Column="5" Content="Rename" Tag="{Binding}"
                                x:Name="BtnRename" Style="{StaticResource GhostBtn}"
                                Padding="6,4" FontSize="10" VerticalAlignment="Center"
                                Margin="4,0,0,0"/>
                        <!-- Delete -->
                        <Button Grid.Column="6" Content="x" Tag="{Binding}"
                                x:Name="BtnDeleteWp" Style="{StaticResource DangerBtn}"
                                VerticalAlignment="Center" Margin="4,0,0,0"/>
                      </Grid>
                    </Border>
                  </DataTemplate>
                </ItemsControl.ItemTemplate>
              </ItemsControl>

              <TextBlock x:Name="TxtEmptyLibrary" Text="No wallpapers yet. Import some files above."
                         Foreground="#CCCCDD" FontSize="13" HorizontalAlignment="Center"
                         Margin="0,32,0,0" Visibility="Visible"/>
            </StackPanel>
          </ScrollViewer>

          <TextBlock Grid.Row="2" x:Name="TxtLibCount" Text=""
                     Foreground="#AAAABD" FontSize="11" Margin="32,8,32,12"/>
        </Grid>

        <!-- TIME -->
        <ScrollViewer x:Name="PageTime" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,28,32,24">
            <TextBlock Text="Time of Day" Foreground="#1A1A2E" FontSize="22"
                       FontFamily="Segoe UI Light" Margin="0,0,0,4"/>
            <TextBlock Text="Set a wallpaper for each time of day"
                       Foreground="#AAAABD" FontSize="12" Margin="0,0,0,24"/>
            <Grid Margin="0,0,0,14">
              <Button x:Name="BtnAddSlot" Content="+ add slot"
                      Style="{StaticResource GhostBtn}" HorizontalAlignment="Right" Padding="12,6"/>
            </Grid>
            <ItemsControl x:Name="TimeSlotsControl">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border Background="White" CornerRadius="10" BorderBrush="#EEEEF5"
                          BorderThickness="1" Padding="18,14" Margin="0,0,0,8">
                    <Border.Effect>
                      <DropShadowEffect Color="#CCCCDD" BlurRadius="8" ShadowDepth="1" Opacity="0.15"/>
                    </Border.Effect>
                    <Grid>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="120"/>
                        <ColumnDefinition Width="90"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="70"/>
                        <ColumnDefinition Width="36"/>
                      </Grid.ColumnDefinitions>
                      <StackPanel Grid.Column="0" Margin="0,0,12,0">
                        <TextBlock Text="LABEL" Foreground="#AAAABD" FontSize="9"
                                   FontFamily="Segoe UI Semibold" Margin="0,0,0,5"/>
                        <TextBox Text="{Binding Label, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"/>
                      </StackPanel>
                      <StackPanel Grid.Column="1" Margin="0,0,12,0">
                        <TextBlock Text="START HH:MM" Foreground="#AAAABD" FontSize="9"
                                   FontFamily="Segoe UI Semibold" Margin="0,0,0,5"/>
                        <TextBox Text="{Binding Start, Mode=TwoWay, UpdateSourceTrigger=LostFocus}"
                                 MaxLength="5" x:Name="TxtSlotStart"/>
                      </StackPanel>
                      <StackPanel Grid.Column="2" Margin="0,0,10,0" VerticalAlignment="Bottom">
                        <TextBlock Text="WALLPAPER" Foreground="#AAAABD" FontSize="9"
                                   FontFamily="Segoe UI Semibold" Margin="0,0,0,5"/>
                        <TextBlock Text="{Binding WallpaperName}" Foreground="#888899"
                                   FontSize="11" TextTrimming="CharacterEllipsis"/>
                      </StackPanel>
                      <Button Grid.Column="3" Content="Browse" Tag="{Binding}"
                              x:Name="BtnBrowseSlot" Style="{StaticResource GhostBtn}"
                              Padding="8,5" VerticalAlignment="Bottom"/>
                      <Button Grid.Column="4" Content="x" Tag="{Binding}"
                              x:Name="BtnRemoveSlot" Style="{StaticResource DangerBtn}"
                              VerticalAlignment="Bottom" Margin="4,0,0,0"/>
                    </Grid>
                  </Border>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </StackPanel>
        </ScrollViewer>

        <!-- WEATHER -->
        <ScrollViewer x:Name="PageWeather" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,28,32,24">
            <TextBlock Text="Weather" Foreground="#1A1A2E" FontSize="22"
                       FontFamily="Segoe UI Light" Margin="0,0,0,4"/>
            <TextBlock Text="Assign wallpapers to weather conditions"
                       Foreground="#AAAABD" FontSize="12" Margin="0,0,0,24"/>
            <Border Background="White" CornerRadius="10" BorderBrush="#E8E8F0"
                    BorderThickness="1" Padding="18,14" Margin="0,0,0,16">
              <Border.Effect>
                <DropShadowEffect Color="#CCCCDD" BlurRadius="10" ShadowDepth="1" Opacity="0.2"/>
              </Border.Effect>
              <StackPanel>
                <TextBlock Text="LOCATION" Foreground="#AAAABD" FontSize="9"
                           FontFamily="Segoe UI Semibold" Margin="0,0,0,10"/>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox x:Name="TxtPlace" Grid.Column="0"/>
                  <Button x:Name="BtnSearch" Content="Search" Grid.Column="2" Style="{StaticResource GhostBtn}"/>
                  <Button x:Name="BtnDetect" Content="Detect" Grid.Column="4" Style="{StaticResource GhostBtn}"/>
                </Grid>
                <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                  <TextBox x:Name="TxtLat" Width="100"/>
                  <TextBlock Text="   /   " Foreground="#DDDDEE" VerticalAlignment="Center" FontSize="14"/>
                  <TextBox x:Name="TxtLon" Width="100"/>
                </StackPanel>
                <TextBlock x:Name="TxtWeatherStatus" Text="" Foreground="#888899"
                           FontSize="11" FontStyle="Italic" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <Border Background="White" CornerRadius="10" BorderBrush="#E8E8F0"
                    BorderThickness="1" Padding="18,14">
              <Border.Effect>
                <DropShadowEffect Color="#CCCCDD" BlurRadius="10" ShadowDepth="1" Opacity="0.2"/>
              </Border.Effect>
              <StackPanel>
                <TextBlock Text="CONDITIONS" Foreground="#AAAABD" FontSize="9"
                           FontFamily="Segoe UI Semibold" Margin="0,0,0,12"/>
                <StackPanel x:Name="WeatherStack"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- SETTINGS -->
        <ScrollViewer x:Name="PageSettings" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="32,28,32,24">
            <TextBlock Text="Settings" Foreground="#1A1A2E" FontSize="22"
                       FontFamily="Segoe UI Light" Margin="0,0,0,4"/>
            <TextBlock Text="Configure paths and automation mode"
                       Foreground="#AAAABD" FontSize="12" Margin="0,0,0,24"/>
            <Border Background="White" CornerRadius="10" BorderBrush="#E8E8F0"
                    BorderThickness="1" Padding="18,16" Margin="0,0,0,12">
              <Border.Effect>
                <DropShadowEffect Color="#CCCCDD" BlurRadius="10" ShadowDepth="1" Opacity="0.2"/>
              </Border.Effect>
              <StackPanel>
                <TextBlock Text="LIVELY EXECUTABLE" Foreground="#AAAABD" FontSize="9"
                           FontFamily="Segoe UI Semibold" Margin="0,0,0,6"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox x:Name="TxtLivelyExe" Grid.Column="0"/>
                  <Button x:Name="BtnBrowseLivelyExe" Content="Browse" Grid.Column="2"
                          Style="{StaticResource GhostBtn}" Padding="12,6"/>
                </Grid>
                <!-- Script path is managed automatically -->
              </StackPanel>
            </Border>
            <Border Background="White" CornerRadius="10" BorderBrush="#E8E8F0"
                    BorderThickness="1" Padding="18,16">
              <Border.Effect>
                <DropShadowEffect Color="#CCCCDD" BlurRadius="10" ShadowDepth="1" Opacity="0.2"/>
              </Border.Effect>
              <StackPanel>
                <TextBlock Text="AUTOMATION MODE" Foreground="#AAAABD" FontSize="9"
                           FontFamily="Segoe UI Semibold" Margin="0,0,0,10"/>
                <StackPanel Orientation="Horizontal">
                  <Border x:Name="BorderModeTime" CornerRadius="6" BorderThickness="1"
                          BorderBrush="#5B4FE8" Background="#F0EEFF"
                          Padding="14,7" Margin="0,0,8,0" Cursor="Hand">
                    <TextBlock x:Name="LblModeTime" Text="Time of Day" Foreground="#5B4FE8" FontSize="12"/>
                  </Border>
                  <Border x:Name="BorderModeWeather" CornerRadius="6" BorderThickness="1"
                          BorderBrush="#E0E0EA" Background="White" Padding="14,7" Cursor="Hand">
                    <TextBlock x:Name="LblModeWeather" Text="Weather" Foreground="#AAAABD" FontSize="12"/>
                  </Border>
                </StackPanel>
                <StackPanel Visibility="Collapsed">
                  <RadioButton x:Name="RadioTime" IsChecked="True"/>
                  <RadioButton x:Name="RadioWeather"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- Footer -->
        <Border x:Name="FooterBar" VerticalAlignment="Bottom" BorderBrush="#EEEEEF" BorderThickness="0,1,0,0"
                Background="White" CornerRadius="0,0,12,0" Padding="20,10">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="StatusText" Foreground="#AAAABD" FontSize="11"
                       VerticalAlignment="Center" Text="ready"/>
            <Button x:Name="BtnTest" Visibility="Collapsed"/>
            <Button x:Name="BtnSave" Content="Save Changes" Grid.Column="1"
                    Style="{StaticResource PrimaryBtn}" Visibility="Collapsed"/>
          </Grid>
        </Border>

      </Grid>
    </Grid>
  </Border>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# ── GET CONTROLS ─────────────────────────────────────────────
$titleBar          = $window.FindName("TitleBar")
$btnMinimize       = $window.FindName("BtnMinimize")

$btnMinimize       = $window.FindName("BtnMinimize")
$btnClose          = $window.FindName("BtnClose")
$navHome           = $window.FindName("NavHome")
$navLibrary        = $window.FindName("NavLibrary")
$navTime           = $window.FindName("NavTime")
$navWeather        = $window.FindName("NavWeather")
$navSettings       = $window.FindName("NavSettings")
$pageOnboarding    = $window.FindName("PageOnboarding")
$pageHome          = $window.FindName("PageHome")
$pageLibrary       = $window.FindName("PageLibrary")
$pageTime          = $window.FindName("PageTime")
$pageWeather       = $window.FindName("PageWeather")
$pageSettings      = $window.FindName("PageSettings")
$dropZone          = $window.FindName("DropZone")
$btnBrowseFiles    = $window.FindName("BtnBrowseFiles")
$btnSkipOnboard    = $window.FindName("BtnSkipOnboard")
$txtOnboardStatus  = $window.FindName("TxtOnboardStatus")
$libDropZone       = $window.FindName("LibDropZone")
$btnImportFiles    = $window.FindName("BtnImportFiles")
$libraryList       = $window.FindName("LibraryList")
$txtEmptyLibrary   = $window.FindName("TxtEmptyLibrary")
$txtLibCount       = $window.FindName("TxtLibCount")
$txtCurrentWp      = $window.FindName("TxtCurrentWallpaper")
$txtCurrentMode    = $window.FindName("TxtCurrentMode")
$txtNextChange     = $window.FindName("TxtNextChange")
$txtLibrarySummary = $window.FindName("TxtLibrarySummary")
$btnTestHome          = $window.FindName("BtnTestHome")
$bannerLivelyMissing  = $window.FindName("BannerLivelyMissing")
$bannerSetupAuto      = $window.FindName("BannerSetupAutomation")
$btnDownloadLively        = $window.FindName("BtnDownloadLively")
$btnCheckLively           = $window.FindName("BtnCheckLively")
$btnOnboardCheckLively    = $window.FindName("BtnOnboardCheckLively")
$bannerOnboardLively      = $window.FindName("BannerOnboardLively")
$btnOnboardDownloadLively = $window.FindName("BtnOnboardDownloadLively")
$btnSetupAutomation   = $window.FindName("BtnSetupAutomation")
$btnSaveHome       = $window.FindName("BtnSaveHome")
$timeSlotsCtrl     = $window.FindName("TimeSlotsControl")
$btnAddSlot        = $window.FindName("BtnAddSlot")
$txtPlace          = $window.FindName("TxtPlace")
$btnSearch         = $window.FindName("BtnSearch")
$btnDetect         = $window.FindName("BtnDetect")
$txtLat            = $window.FindName("TxtLat")
$txtLon            = $window.FindName("TxtLon")
$txtWeatherStatus  = $window.FindName("TxtWeatherStatus")
$weatherStack      = $window.FindName("WeatherStack")
$txtLivelyExe          = $window.FindName("TxtLivelyExe")
$btnBrowseLivelyExe    = $window.FindName("BtnBrowseLivelyExe")

$txtScriptPath     = $null  # Managed internally
$borderModeTime    = $window.FindName("BorderModeTime")
$borderModeWeather = $window.FindName("BorderModeWeather")
$lblModeTime       = $window.FindName("LblModeTime")
$lblModeWeather    = $window.FindName("LblModeWeather")
$radioTime         = $window.FindName("RadioTime")
$radioWeather      = $window.FindName("RadioWeather")
$statusText        = $window.FindName("StatusText")
$btnTest           = $window.FindName("BtnTest")
$btnSave           = $window.FindName("BtnSave")
$footerBar         = $window.FindName("FooterBar")

# Set initial values
$txtLat.Text = $cfgLat
$txtLon.Text = $cfgLon
$txtLivelyExe.Text = $LivelyExe
# ScriptPath is managed internally
$timeSlotsCtrl.ItemsSource = $timeSlots

# ── NAVIGATION ────────────────────────────────────────────────
$allPages   = @($pageOnboarding, $pageHome, $pageLibrary, $pageTime, $pageWeather, $pageSettings)
$allNavBtns = @($navHome, $navLibrary, $navTime, $navWeather, $navSettings)

function Show-Page($page, $activeBtn) {
    foreach ($p in $allPages) { $p.Visibility = "Collapsed" }
    $page.Visibility = "Visible"
    foreach ($b in $allNavBtns) { $b.Style = $window.Resources["NavBtn"] }
    if ($activeBtn) { $activeBtn.Style = $window.Resources["NavBtnActive"] }
}

function Update-LibraryUI {
    $libraryList.ItemsSource = $null
    $libraryList.ItemsSource = $wallpaperLibrary
    $txtEmptyLibrary.Visibility = if ($wallpaperLibrary.Count -eq 0) { "Visible" } else { "Collapsed" }
    $txtLibCount.Text = "$($wallpaperLibrary.Count) wallpaper(s) in library"
}

function Test-TaskExists {
    $task = Get-ScheduledTask -TaskName "LivelyWallpaperChanger" -ErrorAction SilentlyContinue
    return ($null -ne $task)
}

function Update-HomeStats {
    # Current wallpaper
    $currentWp = if (Test-Path $StateFile) { (Get-Content $StateFile -Raw).Trim() } else { "" }
    $wpName = if ($currentWp -and (Test-Path $currentWp -ErrorAction SilentlyContinue)) { Get-WallpaperName $currentWp } else { "--" }
    $txtCurrentWp.Text = $wpName

    # Mode
    $txtCurrentMode.Text = if ($radioWeather.IsChecked) { "Weather" } else { "Time of Day" }

    # Next change - only show if slots are configured with wallpapers
    $configuredSlots = @($timeSlots | Where-Object { $_.WallpaperPath -and (Test-Path $_.WallpaperPath -ErrorAction SilentlyContinue) })
    if ($configuredSlots.Count -gt 0) {
        $now = (Get-Date).Hour * 60 + (Get-Date).Minute
        $nextSlot = $null
        foreach ($slot in $configuredSlots) {
            if (-not $slot.Start) { continue }
            $slotMins = Get-SlotMinutes $slot.Start
            if ($slotMins -gt $now) { $nextSlot = $slot; break }
        }
        if (-not $nextSlot) { $nextSlot = $configuredSlots[0] }
        $txtNextChange.Text = "$($nextSlot.Label) at $($nextSlot.Start)"
    } else {
        $txtNextChange.Text = "--"
    }

    # Library summary
    $txtLibrarySummary.Text = if ($wallpaperLibrary.Count -gt 0) {
        "$($wallpaperLibrary.Count) wallpaper(s): " + (($wallpaperLibrary | ForEach-Object { $_.Title }) -join ", ")
    } else { "No wallpapers imported yet. Visit the Library tab." }

    # Show/hide banners
    $bannerLivelyMissing.Visibility = if ($livelyInstalled) { "Collapsed" } else { "Visible" }
    $bannerSetupAuto.Visibility = if (-not (Test-TaskExists)) { "Visible" } else { "Collapsed" }
}

$navHome.Add_Click({
    Update-HomeStats; Show-Page $pageHome $navHome
    $footerBar.Visibility = "Visible"
    $btnSave.Visibility = "Collapsed"
})
$navLibrary.Add_Click({
    Update-LibraryUI; Show-Page $pageLibrary $navLibrary
    $footerBar.Visibility = "Visible"
    $btnSave.Visibility = "Collapsed"
})
$navTime.Add_Click({
    Show-Page $pageTime $navTime
    $footerBar.Visibility = "Visible"
    $btnSave.Visibility = "Visible"
})
$navWeather.Add_Click({
    Show-Page $pageWeather $navWeather
    $footerBar.Visibility = "Visible"
    $btnSave.Visibility = "Visible"
})
$navSettings.Add_Click({
    Show-Page $pageSettings $navSettings
    $footerBar.Visibility = "Visible"
    $btnSave.Visibility = "Collapsed"
})

# ── TITLE BAR ────────────────────────────────────────────────
$titleBar.Add_MouseLeftButtonDown({ $window.DragMove() })


$btnMinimize.Add_Click({ $window.WindowState = "Minimized" })
$btnClose.Add_Click({ $window.Close() })

$btnBrowseLivelyExe.Add_Click({
    $ofd = [System.Windows.Forms.OpenFileDialog]::new()
    $ofd.Title = "Locate Lively.exe"
    $ofd.Filter = "Executable files (*.exe)|*.exe|All files (*.*)|*.*"
    $ofd.FileName = "Lively.exe"
    if ($txtLivelyExe.Text -and (Test-Path (Split-Path $txtLivelyExe.Text) -ErrorAction SilentlyContinue)) {
        $ofd.InitialDirectory = Split-Path $txtLivelyExe.Text
    }
    if ($ofd.ShowDialog() -eq "OK") {
        $txtLivelyExe.Text = $ofd.FileName
        $script:LivelyExe = $ofd.FileName
        $statusText.Text = "Lively path updated"
    }
})



$btnDownloadLively.Add_Click({
    Start-Process "https://rocksdanister.github.io/lively/"
})
$btnOnboardDownloadLively.Add_Click({
    Start-Process "https://rocksdanister.github.io/lively/"
})

$checkLivelyAction = {
    $detected = Find-LivelyExe
    if ($detected) {
        $script:LivelyExe = $detected
        $script:livelyInstalled = $true
        $txtLivelyExe.Text = $detected
        $bannerLivelyMissing.Visibility = "Collapsed"
        $bannerOnboardLively.Visibility = "Collapsed"
        $statusText.Text = "Lively found at $detected"
    } else {
        $statusText.Text = "Lively still not found - please install it first"
    }
}

$btnCheckLively.Add_Click($checkLivelyAction)
$btnOnboardCheckLively.Add_Click($checkLivelyAction)

$btnSetupAutomation.Add_Click({
    $statusText.Text = "Setting up automation..."
    $sp = $txtScriptPath.Text

    # Make sure script exists first
    if (-not (Test-Path $sp)) {
        Do-Save
    }

    # Build trigger lines before the here-string
    $triggerLines = ($timeSlots | ForEach-Object {
        $t = if ($_.Start) { $_.Start.Trim() } else { "06:00" }
        if ($t -notmatch "^\d{1,2}:\d{2}$") { $t = "$($t.PadLeft(2,'0')):00" }
        "(New-ScheduledTaskTrigger -Daily -At '$t')"
    }) -join ","

    # Write a small setup script and run it elevated
    $setupScript = @"
`$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c start /min powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File ``"$sp``""
`$triggers = @($triggerLines)
`$principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
`$settings = New-ScheduledTaskSettingsSet -Hidden
Unregister-ScheduledTask -TaskName "LivelyWallpaperChanger" -Confirm:`$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName "LivelyWallpaperChanger" -Action `$action -Trigger `$triggers -Principal `$principal -Settings `$settings
Enable-ScheduledTask -TaskName "LivelyWallpaperChanger"
"@
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    $setupScript | Out-File -FilePath $tmp -Encoding UTF8
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$tmp`"" -Verb RunAs -Wait
    Start-Sleep -Milliseconds 500

    if (Test-TaskExists) {
        $bannerSetupAuto.Visibility = "Collapsed"
        $statusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#22AA66")
        $statusText.Text = "Automation set up successfully"
        $window.Dispatcher.BeginInvoke([Action]{
            Start-Sleep -Seconds 3
            $statusText.Text = "ready"
            $statusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#AAAABD")
        }, [System.Windows.Threading.DispatcherPriority]::Background)
    } else {
        $statusText.Text = "Setup may have been cancelled - try again"
    }
})

# ── IMPORT FILES ─────────────────────────────────────────────
function Import-Files($files) {
    $imported = 0
    $skipped  = 0
    $validExts = @(".mp4",".gif",".jpg",".jpeg",".png",".webm",".avi",".mkv")
    foreach ($file in $files) {
        $ext = [System.IO.Path]::GetExtension($file).ToLower()
        if ($validExts -contains $ext) {
            $dest = Join-Path $WallpaperDir ([System.IO.Path]::GetFileName($file))
            if (-not (Test-Path $dest)) {
                Copy-Item $file $dest
                $imported++
            } else { $skipped++ }
        }
    }
    Reload-Library
    Update-LibraryUI
    return @{ Imported=$imported; Skipped=$skipped }
}

function Show-FileDialog {
    $ofd = [System.Windows.Forms.OpenFileDialog]::new()
    $ofd.Title = "Select wallpaper files"
    $ofd.Filter = "Media files (*.mp4;*.gif;*.jpg;*.jpeg;*.png;*.webm;*.avi;*.mkv)|*.mp4;*.gif;*.jpg;*.jpeg;*.png;*.webm;*.avi;*.mkv|All files (*.*)|*.*"
    $ofd.Multiselect = $true
    if ($ofd.ShowDialog() -eq "OK") { return $ofd.FileNames }
    return @()
}

# Onboarding import
$btnBrowseFiles.Add_Click({
    $files = Show-FileDialog
    if ($files.Count -gt 0) {
        $result = Import-Files $files
        $txtOnboardStatus.Text = "Imported $($result.Imported) file(s)$(if($result.Skipped -gt 0){", $($result.Skipped) already existed"})."
        if ($result.Imported -gt 0) {
            $cfg = [PSCustomObject]@{ SetupDone=$true; Lat=$cfgLat; Lon=$cfgLon }
            Save-Config $cfg
            Start-Sleep -Milliseconds 800
            Update-HomeStats
            Show-Page $pageHome $navHome
        }
    }
})

$btnSkipOnboard.Add_Click({
    $cfg = [PSCustomObject]@{ SetupDone=$true; Lat=$cfgLat; Lon=$cfgLon }
    Save-Config $cfg
    Update-HomeStats
    Show-Page $pageHome $navHome
})

# Drag and drop - onboarding
$dropZone.Add_Drop({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        $result = Import-Files $files
        $txtOnboardStatus.Text = "Imported $($result.Imported) file(s)."
        if ($result.Imported -gt 0) {
            $cfg = [PSCustomObject]@{ SetupDone=$true; Lat=$cfgLat; Lon=$cfgLon }
            Save-Config $cfg
            Start-Sleep -Milliseconds 600
            Update-HomeStats
            Show-Page $pageHome $navHome
        }
    }
})
$dropZone.Add_DragOver({ param($s,$e); $e.Effects = [System.Windows.DragDropEffects]::Copy; $e.Handled = $true })

# Library import button
$btnImportFiles.Add_Click({
    $files = Show-FileDialog
    if ($files.Count -gt 0) {
        $result = Import-Files $files
        $statusText.Text = "Imported $($result.Imported) file(s)$(if($result.Skipped -gt 0){", $($result.Skipped) skipped"})."
    }
})

# Drag and drop - library page
$libDropZone.Add_MouseLeftButtonUp({ $btnImportFiles.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent)) })

# Handle drag and drop at the window level
$window.Add_DragOver({ param($s,$e); $e.Effects = [System.Windows.DragDropEffects]::Copy; $e.Handled = $true })
$window.Add_Drop({
    param($s, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        $result = Import-Files $files
        $statusText.Text = "Imported $($result.Imported) file(s)."
        Update-LibraryUI
        # Switch to library page to show imported files
        Show-Page $pageLibrary $navLibrary
        $footerBar.Visibility = "Visible"
        $btnSave.Visibility = "Collapsed"
    }
    $e.Handled = $true
})

# Library list events (preview, rename, delete)
$libraryList.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $btn = $e.OriginalSource
        if ($btn -isnot [System.Windows.Controls.Button]) { return }
        $wp = $btn.Tag
        if ($null -eq $wp) { return }

        if ($btn.Content -eq "Set") {
            & $LivelyExe setwp --file $wp.Path
            Set-Content -Path $StateFile -Value $wp.Path -Encoding UTF8 -NoNewline
            Start-Sleep -Milliseconds 500
            Clean-LivelyLibrary
            $statusText.Text = "Wallpaper set to $($wp.Title)"

        } elseif ($btn.Content -eq "Preview") {
            $previousWp = if (Test-Path $StateFile) { (Get-Content $StateFile -Raw).Trim() } else { "" }
            & $LivelyExe setwp --file $wp.Path
            $statusText.Text = "Previewing: $($wp.Title) - restoring in 5 seconds..."
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromSeconds(5)
            $timer.Tag = [PSCustomObject]@{
                RestorePath = $previousWp
                LivelyPath  = $LivelyExe
                StateFile   = $StateFile
                Status      = $statusText
            }
            $timer.Add_Tick({
                param($t, $e)
                $t.Stop()
                $ctx = $t.Tag
                if ($ctx.RestorePath -and (Test-Path $ctx.RestorePath)) {
                    & $ctx.LivelyPath setwp --file $ctx.RestorePath
                    Set-Content -Path $ctx.StateFile -Value $ctx.RestorePath -Encoding UTF8 -NoNewline
                    $ctx.Status.Text = "Preview ended - wallpaper restored"
                } else {
                    $ctx.Status.Text = "Preview ended"
                }
            })
            $timer.Start()

        } elseif ($btn.Content -eq "Rename") {
            # Simple rename dialog
            [xml]$rd = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Rename" Width="340" Height="150"
        WindowStartupLocation="CenterOwner" Background="#F4F5F7" FontFamily="Segoe UI"
        WindowStyle="SingleBorderWindow" ResizeMode="NoResize">
    <StackPanel Margin="20">
        <TextBlock Text="New name:" Foreground="#AAAABD" FontSize="11" Margin="0,0,0,6"/>
        <TextBox x:Name="TxtNewName" Padding="8,6" BorderBrush="#E0E0EA" BorderThickness="1"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnOk" Content="Rename" Width="80" Height="30"
                    Background="#5B4FE8" Foreground="White" BorderThickness="0" Cursor="Hand" Margin="0,0,0,0"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
            $rr = [System.Xml.XmlNodeReader]::new($rd)
            $rw = [System.Windows.Markup.XamlReader]::Load($rr)
            $rw.Owner = $window
            $tn = $rw.FindName("TxtNewName")
            $tn.Text = $wp.Title
            $rw.FindName("BtnOk").Add_Click({
                $newName = $tn.Text.Trim()
                if ($newName -and $newName -ne $wp.Title) {
                    $newPath = Join-Path $WallpaperDir ($newName + [System.IO.Path]::GetExtension($wp.Path))
                    Rename-Item $wp.Path $newPath -ErrorAction SilentlyContinue
                    Reload-Library
                    Update-LibraryUI
                    $statusText.Text = "Renamed to $newName"
                }
                $rw.Close()
            })
            $rw.ShowDialog() | Out-Null

        } elseif ($btn.Content -eq "x") {
            $msg = [System.Windows.MessageBox]::Show("Remove '$($wp.Title)' from library?", "Confirm", "YesNo", "Question")
            if ($msg -eq "Yes") {
                Remove-Item $wp.Path -ErrorAction SilentlyContinue
                Reload-Library
                Update-LibraryUI
                $statusText.Text = "Removed $($wp.Title)"
            }
        }
    }
)

# ── WALLPAPER PICKER (for time/weather slots) ─────────────────
function Show-WallpaperPicker {
    if ($wallpaperLibrary.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No wallpapers in library. Import some files first via the Library tab.", "No wallpapers", "OK", "Information") | Out-Null
        return $null
    }
    [xml]$px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Choose Wallpaper" Width="420" Height="360"
        WindowStartupLocation="CenterOwner" Background="#F4F5F7" FontFamily="Segoe UI"
        WindowStyle="SingleBorderWindow" ResizeMode="NoResize">
    <Border Background="White" CornerRadius="0" Margin="0">
        <Grid Margin="20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Text="Choose a wallpaper" Foreground="#1A1A2E"
                       FontSize="14" FontFamily="Segoe UI Semibold" Margin="0,0,0,12"/>
            <ListBox x:Name="WpList" Grid.Row="1" Background="#F8F8FC"
                     BorderBrush="#EEEEF5" BorderThickness="1"
                     Foreground="#222233" FontSize="13" Padding="4"/>
            <StackPanel Grid.Row="2" Orientation="Horizontal"
                        HorizontalAlignment="Right" Margin="0,12,0,0">
                <Button x:Name="BtnCancel" Content="Cancel" Width="80" Height="32"
                        Background="White" Foreground="#888899" BorderBrush="#E0E0EA"
                        BorderThickness="1" Margin="0,0,8,0" Cursor="Hand"/>
                <Button x:Name="BtnOk" Content="Select" Width="80" Height="32"
                        Background="#5B4FE8" Foreground="White"
                        BorderThickness="0" Cursor="Hand"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
'@
    $pr = [System.Xml.XmlNodeReader]::new($px)
    $pw = [System.Windows.Markup.XamlReader]::Load($pr)
    $pw.Owner = $window
    $list = $pw.FindName("WpList")
    $pw.FindName("BtnCancel").Add_Click({ $pw.DialogResult = $false; $pw.Close() })
    $pw.FindName("BtnOk").Add_Click({ $pw.DialogResult = $true; $pw.Close() })
    foreach ($wp in $wallpaperLibrary) { $list.Items.Add($wp.Title) | Out-Null }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    if ($pw.ShowDialog() -and $list.SelectedIndex -ge 0) { return $wallpaperLibrary[$list.SelectedIndex] }
    return $null
}

# ── TIME SLOT EVENTS ──────────────────────────────────────────
$timeSlotsCtrl.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $btn = $e.OriginalSource
        if ($btn -isnot [System.Windows.Controls.Button]) { return }
        $slot = $btn.Tag
        if ($null -eq $slot -or $slot -isnot [PSCustomObject]) { return }
        if ($btn.Content -eq "Browse") {
            $sel = Show-WallpaperPicker
            if ($sel) {
                $slot.WallpaperPath = $sel.Path
                $slot.WallpaperName = $sel.Title
                $timeSlotsCtrl.Items.Refresh()
                $statusText.Text = "Set $($slot.Label) -> $($sel.Title)"
            }
        } elseif ($btn.Content -eq "x") {
            $timeSlots.Remove($slot) | Out-Null
        }
    }
)

$btnAddSlot.Add_Click({
    $timeSlots.Add([PSCustomObject]@{ Label="New Slot"; Start="00:00"; WallpaperPath=""; WallpaperName="(not set)" })
})

# ── WEATHER ───────────────────────────────────────────────────
$weatherControls = @{}
function Build-WeatherRows {
    $weatherStack.Children.Clear()
    $script:weatherControls = @{}
    foreach ($condition in @("Clear","Cloudy","Rainy","Snowy","Stormy","Foggy")) {
        $row = [System.Windows.Controls.Grid]::new()
        $row.Margin = [System.Windows.Thickness]::new(0,0,0,10)
        $c0 = [System.Windows.Controls.ColumnDefinition]::new(); $c0.Width = [System.Windows.GridLength]::new(80)
        $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::Auto
        $row.ColumnDefinitions.Add($c0); $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)

        $lbl = [System.Windows.Controls.TextBlock]::new()
        $lbl.Text = $condition.ToUpper()
        $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#AAAABD")
        $lbl.FontSize = 9
        $lbl.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe UI Semibold")
        $lbl.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($lbl, 0)

        $nameLbl = [System.Windows.Controls.TextBlock]::new()
        $nameLbl.Text = Get-WallpaperName $cfgWeather[$condition]
        $nameLbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#888899")
        $nameLbl.FontSize = 11
        $nameLbl.VerticalAlignment = "Center"
        $nameLbl.TextTrimming = "CharacterEllipsis"
        $nameLbl.Margin = [System.Windows.Thickness]::new(0,0,8,0)
        [System.Windows.Controls.Grid]::SetColumn($nameLbl, 1)

        $btn = [System.Windows.Controls.Button]::new()
        $btn.Content = "browse"
        $btn.Style = $window.Resources["GhostBtn"]
        $btn.Padding = [System.Windows.Thickness]::new(10,5,10,5)
        $btn.Cursor = [System.Windows.Input.Cursors]::Hand
        $btn.Tag = $condition
        [System.Windows.Controls.Grid]::SetColumn($btn, 2)

        $row.Children.Add($lbl) | Out-Null
        $row.Children.Add($nameLbl) | Out-Null
        $row.Children.Add($btn) | Out-Null
        $weatherStack.Children.Add($row) | Out-Null
        $script:weatherControls[$condition] = @{ NameLabel=$nameLbl }

        $btn.Add_Click({
            param($s2, $e2)
            $cond = $s2.Tag
            $sel = Show-WallpaperPicker
            if ($sel) {
                $cfgWeather[$cond] = $sel.Path
                $script:weatherControls[$cond].NameLabel.Text = $sel.Title
                $statusText.Text = "Set $cond -> $($sel.Title)"
            }
        })
    }
}
Build-WeatherRows

function Get-WeatherDescription($lat, $lon, $locationName) {
    try {
        $url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=weather_code,temperature_2m&temperature_unit=celsius&forecast_days=1"
        $r = Invoke-RestMethod $url -TimeoutSec 8
        $code = $r.current.weather_code
        $temp = [math]::Round($r.current.temperature_2m)
        $desc = switch ($code) {
            0 {"clear skies"} 1 {"mainly clear"} 2 {"partly cloudy"} 3 {"overcast"}
            { $_ -in 45,48 } {"foggy"} { $_ -in 51,53,55 } {"drizzling"}
            { $_ -in 61,63 } {"raining"} 65 {"heavy rain"}
            { $_ -in 71,73 } {"snowing"} 75 {"heavy snow"}
            { $_ -in 80,81,82 } {"rain showers"} { $_ -in 95,96,99 } {"thunderstorms"}
            default {"mixed conditions"}
        }
        return "$locationName. Currently $desc, ${temp}C."
    } catch { return $locationName }
}

$btnDetect.Add_Click({
    $statusText.Text = "Detecting location..."
    try {
        $loc = Invoke-RestMethod "https://ipinfo.io/json" -TimeoutSec 6
        $coords = $loc.loc -split ","
        $txtLat.Text = $coords[0].Trim(); $txtLon.Text = $coords[1].Trim()
        $locName = "$($loc.city), $($loc.country)"
        $txtWeatherStatus.Text = Get-WeatherDescription $txtLat.Text $txtLon.Text $locName
        $statusText.Text = "Location: $locName"
    } catch {
        try {
            $loc = Invoke-RestMethod "http://ip-api.com/json/" -TimeoutSec 6
            $txtLat.Text = "$($loc.lat)"; $txtLon.Text = "$($loc.lon)"
            $locName = "$($loc.city), $($loc.country)"
            $txtWeatherStatus.Text = Get-WeatherDescription $txtLat.Text $txtLon.Text $locName
            $statusText.Text = "Location: $locName"
        } catch { $statusText.Text = "Could not detect location" }
    }
})

$btnSearch.Add_Click({
    $place = $txtPlace.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($place)) { $statusText.Text = "Enter a place name first"; return }
    $statusText.Text = "Searching..."
    try {
        $encoded = [System.Uri]::EscapeDataString($place)
        $results = Invoke-RestMethod "https://nominatim.openstreetmap.org/search?q=$encoded&format=json&limit=1" -TimeoutSec 8 -Headers @{ "User-Agent"="Livecycle/1.0" }
        if ($results -and $results.Count -gt 0) {
            $txtLat.Text = $results[0].lat; $txtLon.Text = $results[0].lon
            $locName = ($results[0].display_name.Split(',')[0..1] -join ',').Trim()
            $txtWeatherStatus.Text = Get-WeatherDescription $txtLat.Text $txtLon.Text $locName
            $statusText.Text = "Found: $locName"
        } else { $statusText.Text = "Place not found" }
    } catch { $statusText.Text = "Search failed" }
})

# ── MODE TOGGLE ───────────────────────────────────────────────
function Set-ModeTime {
    $radioTime.IsChecked = $true
    $borderModeTime.BorderBrush    = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#5B4FE8")
    $borderModeTime.Background     = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F0EEFF")
    $lblModeTime.Foreground        = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#5B4FE8")
    $borderModeWeather.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#E0E0EA")
    $borderModeWeather.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFrom("White")
    $lblModeWeather.Foreground     = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#AAAABD")
}
function Set-ModeWeather {
    $radioWeather.IsChecked = $true
    $borderModeWeather.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#5B4FE8")
    $borderModeWeather.Background  = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#F0EEFF")
    $lblModeWeather.Foreground     = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#5B4FE8")
    $borderModeTime.BorderBrush    = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#E0E0EA")
    $borderModeTime.Background     = [System.Windows.Media.BrushConverter]::new().ConvertFrom("White")
    $lblModeTime.Foreground        = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#AAAABD")
}
$borderModeTime.Add_MouseLeftButtonUp({ Set-ModeTime })
$borderModeWeather.Add_MouseLeftButtonUp({ Set-ModeWeather })
if ($currentMode -eq "weather") { Set-ModeWeather } else { Set-ModeTime }

# ── BUILD SCRIPT ──────────────────────────────────────────────
function Build-Script {
    $mode = if ($radioWeather.IsChecked) { "weather" } else { "time" }
    $lat  = $txtLat.Text; $lon = $txtLon.Text
    $livelyExePath = $txtLivelyExe.Text
    if ([string]::IsNullOrWhiteSpace($livelyExePath)) {
        [System.Windows.MessageBox]::Show("Lively Wallpaper is not installed or the path is not set. Please install Lively first.", "Lively Not Found", "OK", "Warning") | Out-Null
        return ""
    }

    $wpBlock = ""
    foreach ($slot in $timeSlots) {
        $wpBlock += "    $($slot.Label.PadRight(12))= `"$($slot.WallpaperPath)`"`n"
    }
    foreach ($w in @("Clear","Cloudy","Rainy","Snowy","Stormy","Foggy")) {
        $wpBlock += "    $($w.PadRight(12))= `"$($cfgWeather[$w])`"`n"
    }

    # Build sorted start times list for the generated script
    $startMinsList = ($timeSlots | ForEach-Object {
        $s = Format-TimeInput $_.Start
        $m = Get-SlotMinutes $s
        "`"$($_.Label)`"=$m"
    }) -join ";"
    $defaultSlot = if ($timeSlots.Count -gt 0) { $timeSlots[0].Label } else { "Night" }

    return @"
# Auto-generated by Livecycle - $(Get-Date -Format "yyyy-MM-dd HH:mm")

`$LivelyExe = "$livelyExePath"
`$Mode      = "$mode"
`$Latitude  = $lat
`$Longitude = $lon

`$Wallpapers = @{
$wpBlock}

function Set-WallpaperByTime {
    `$mins = (Get-Date).Hour * 60 + (Get-Date).Minute
    `$slots = @{$startMinsList}
    # Find the slot whose start time is the most recent past time
    `$best = "$defaultSlot"
    `$bestMins = -1
    foreach (`$entry in `$slots.GetEnumerator()) {
        `$sm = `$entry.Value
        # Handle overnight: if slot start > current, subtract 1440 (24hrs)
        `$adj = if (`$sm -gt `$mins) { `$sm - 1440 } else { `$sm }
        if (`$adj -gt `$bestMins) { `$bestMins = `$adj; `$best = `$entry.Key }
    }
    return `$Wallpapers[`$best]
}

function Get-WeatherCode {
    `$url = "https://api.open-meteo.com/v1/forecast?latitude=`$Latitude&longitude=`$Longitude&current=weather_code&forecast_days=1"
    try { `$r = Invoke-RestMethod -Uri `$url -TimeoutSec 10; return `$r.current.weather_code } catch { return `$null }
}

function Set-WallpaperByWeather {
    `$code = Get-WeatherCode
    if (`$null -eq `$code) { return Set-WallpaperByTime }
    `$slot = switch (`$code) {
        0 {"Clear"} { `$_ -in 1,2,3 } {"Cloudy"} { `$_ -in 45,48 } {"Foggy"}
        { `$_ -in 51,53,55,56,57 } {"Rainy"} { `$_ -in 61,63,65,66,67 } {"Rainy"}
        { `$_ -in 71,73,75,77 } {"Snowy"} { `$_ -in 80,81,82 } {"Rainy"}
        { `$_ -in 85,86 } {"Snowy"} { `$_ -in 95,96,99 } {"Stormy"} default {"Cloudy"}
    }
    return `$Wallpapers[`$slot]
}

`$wallpaperPath = switch (`$Mode) {
    "time"    { Set-WallpaperByTime }
    "weather" { Set-WallpaperByWeather }
    default   { Write-Error "Unknown mode"; exit 1 }
}

if ([string]::IsNullOrWhiteSpace(`$wallpaperPath)) { Write-Host "No wallpaper for this slot."; exit 0 }
if (-not (Test-Path `$wallpaperPath)) { Write-Error "Not found: `$wallpaperPath"; exit 1 }

`$stateFile = "$StateFile"
`$currentWallpaper = if (Test-Path `$stateFile) { Get-Content `$stateFile -Raw } else { "" }
if (`$currentWallpaper.Trim() -eq `$wallpaperPath.Trim()) { Write-Host "Already set."; exit 0 }

Write-Host "Setting: `$wallpaperPath"
& "`$LivelyExe" setwp --file `$wallpaperPath
Set-Content -Path `$stateFile -Value `$wallpaperPath -Encoding UTF8 -NoNewline
Write-Host "Done."
"@
}

function Get-SlotMinutes($timeStr) {
    if (-not $timeStr) { return 0 }
    $parts = $timeStr -split ":"
    $h = [int]$parts[0]
    $m = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
    return $h * 60 + $m
}

function Format-TimeInput($t) {
    # Auto-format: "1800" -> "18:00", "340" -> "03:40", "18:00" unchanged
    if (-not $t) { return $t }
    $t = $t.Trim()
    # Already has colon - leave it
    if ($t -match ":") { return $t }
    # 4 digits: 1800 -> 18:00
    if ($t -match "^\d{4}$") { return "$($t.Substring(0,2)):$($t.Substring(2,2))" }
    # 3 digits: 340 -> 03:40
    if ($t -match "^\d{3}$") { return "0$($t.Substring(0,1)):$($t.Substring(1,2))" }
    # 1-2 digits: treat as hour with :00
    if ($t -match "^\d{1,2}$") { return "$($t.PadLeft(2,'0')):00" }
    return $t
}

function Validate-TimeFormat($t) {
    if (-not $t) { return $false }
    $t = Format-TimeInput $t
    if ($t -notmatch "^\d{2}:\d{2}$") { return $false }
    $parts = $t -split ":"
    $h = [int]$parts[0]; $m = [int]$parts[1]
    return ($h -ge 0 -and $h -le 23 -and $m -ge 0 -and $m -le 59)
}

function Test-SlotConflicts {
    $slots = @($timeSlots)
    $errors = @()

    # Check format
    foreach ($slot in $slots) {
        if (-not (Validate-TimeFormat $slot.Start)) {
            $errors += "$($slot.Label): start time '$($slot.Start)' is not valid. Use HH:MM (e.g. 06:00)"
        }
    }
    if ($errors.Count -gt 0) { return $errors }

    # Check for duplicate start times
    for ($i = 0; $i -lt $slots.Count; $i++) {
        for ($j = $i + 1; $j -lt $slots.Count; $j++) {
            $aStart = Get-SlotMinutes (Format-TimeInput $slots[$i].Start)
            $bStart = Get-SlotMinutes (Format-TimeInput $slots[$j].Start)
            if ($aStart -eq $bStart) {
                $errors += "$($slots[$i].Label) and $($slots[$j].Label) have the same start time ($($slots[$i].Start))"
            }
        }
    }
    return $errors
}

function Do-Save {
    # Validate slots first
    $conflicts = Test-SlotConflicts
    if ($conflicts.Count -gt 0) {
        $msg = "Please fix the following conflicts before saving:`n`n" + ($conflicts -join "`n")
        [System.Windows.MessageBox]::Show($msg, "Time Slot Conflicts", "OK", "Warning") | Out-Null
        return
    }

    try {
        $sp = $ScriptPath
        Build-Script | Out-File -FilePath $sp -Encoding UTF8
        $taskName = "LivelyWallpaperChanger"
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            # Build trigger update script and run elevated
            $triggerTimes = ($timeSlots | ForEach-Object {
                $t = if ($_.Start) { $_.Start.Trim() } else { "06:00" }
                "'$t'"
            }) -join ","
            $updateScript = @"
`$triggers = @($triggerTimes) | ForEach-Object { New-ScheduledTaskTrigger -Daily -At `$_ }
Set-ScheduledTask -TaskName 'LivelyWallpaperChanger' -Trigger `$triggers
"@
            $tmpTrigger = [System.IO.Path]::GetTempFileName() + ".ps1"
            $updateScript | Out-File -FilePath $tmpTrigger -Encoding UTF8
            Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$tmpTrigger`"" -Verb RunAs -Wait -WindowStyle Hidden
        }
        $slotsToSave = @($timeSlots | ForEach-Object {
            @{ Label=$_.Label
               Start=(Format-TimeInput $_.Start)
               WallpaperPath=$_.WallpaperPath }
        })
        $weatherToSave = @{}
        foreach ($w in @("Clear","Cloudy","Rainy","Snowy","Stormy","Foggy")) {
            $weatherToSave[$w] = $cfgWeather[$w]
        }
        $cfgMode = if ($radioWeather.IsChecked) { "weather" } else { "time" }
        $cfg = [PSCustomObject]@{
            SetupDone=$true; Lat=$txtLat.Text; Lon=$txtLon.Text
            Mode=$cfgMode; Slots=$slotsToSave; Weather=$weatherToSave
        }
        Save-Config $cfg
        # Run the script immediately so changes take effect now
        $sp2 = $ScriptPath
        if (Test-Path $sp2) {
            Remove-Item $StateFile -ErrorAction SilentlyContinue
            Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sp2`"" -Wait
            Start-Sleep -Milliseconds 500
            Clean-LivelyLibrary
        }

        $statusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#22AA66")
        $statusText.Text = "Saved and applied immediately"
        $window.Dispatcher.BeginInvoke([Action]{
            Start-Sleep -Seconds 3
            $statusText.Text = "ready"
            $statusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#AAAABD")
        }, [System.Windows.Threading.DispatcherPriority]::Background)
    } catch {
        $statusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#CC4444")
        $statusText.Text = "Error: $_"
    }
}

function Do-Test {
    $statusText.Text = "Running test..."
    $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
    Build-Script | Out-File -FilePath $tmp -Encoding UTF8
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$tmp`"" -Wait -WindowStyle Hidden
    $statusText.Text = "Test complete - check your wallpaper!"
}

$btnSave.Add_Click({ Do-Save })
$btnTest.Add_Click({ Do-Test })
$btnSaveHome.Add_Click({ Do-Save })
$btnTestHome.Add_Click({ Do-Test })

# ── INITIAL PAGE ──────────────────────────────────────────────
Update-LibraryUI
if ($firstRun -or $wallpaperLibrary.Count -eq 0) {
    Show-Page $pageOnboarding $null
    $footerBar.Visibility = "Visible"
    $btnSave.Visibility = "Collapsed"
    $bannerOnboardLively.Visibility = if (-not $livelyInstalled) { "Visible" } else { "Collapsed" }
} else {
    Update-HomeStats
    Show-Page $pageHome $navHome
    $footerBar.Visibility = "Visible"
    $btnSave.Visibility = "Collapsed"
}

$window.ShowDialog() | Out-Null
