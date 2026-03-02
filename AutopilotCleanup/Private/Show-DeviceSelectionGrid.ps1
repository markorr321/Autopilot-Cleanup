function Show-DeviceSelectionGrid {
    param (
        [Parameter(Mandatory)]
        [array]$Devices,
        [string]$Title = "Select Devices to Remove from All Services"
    )

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # Store devices with selection state
    $script:deviceList = [System.Collections.ArrayList]::new()
    foreach ($device in $Devices) {
        $null = $script:deviceList.Add([PSCustomObject]@{
            Selected     = $false
            DisplayName  = $device.DisplayName
            SerialNumber = $device.SerialNumber
            Model        = $device.Model
            GroupTag     = $device.GroupTag
            IntuneFound  = $device.IntuneFound
            EntraFound   = $device.EntraFound
            IntuneName   = $device.IntuneName
            EntraName    = $device.EntraName
            Original     = $device
        })
    }

    $script:filteredList = [System.Collections.ArrayList]::new($script:deviceList)

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Height="700" Width="1200" WindowStartupLocation="CenterScreen">
    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBox Name="SearchBox" Grid.Row="0" Margin="0,0,0,10" Padding="5" FontSize="14"/>
        <TextBlock Grid.Row="0" Margin="5,5,0,0" Foreground="Gray" IsHitTestVisible="False" Name="SearchPlaceholder">Search devices...</TextBlock>

        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
            <Button Name="SelectAllBtn" Content="Select All" Padding="10,5" Margin="0,0,10,0"/>
            <Button Name="ClearAllBtn" Content="Clear All" Padding="10,5" Margin="0,0,10,0"/>
            <TextBlock Name="CountLabel" VerticalAlignment="Center" Foreground="Gray" FontSize="14"/>
        </StackPanel>

        <ListView Name="DeviceList" Grid.Row="2" SelectionMode="Multiple">
            <ListView.View>
                <GridView>
                    <GridViewColumn Width="40">
                        <GridViewColumn.CellTemplate>
                            <DataTemplate>
                                <CheckBox IsChecked="{Binding Selected, Mode=TwoWay}" Margin="5,0,0,0"/>
                            </DataTemplate>
                        </GridViewColumn.CellTemplate>
                    </GridViewColumn>
                    <GridViewColumn Header="Display Name" Width="180" DisplayMemberBinding="{Binding DisplayName}"/>
                    <GridViewColumn Header="Serial Number" Width="220" DisplayMemberBinding="{Binding SerialNumber}"/>
                    <GridViewColumn Header="Model" Width="120" DisplayMemberBinding="{Binding Model}"/>
                    <GridViewColumn Header="Group Tag" Width="80" DisplayMemberBinding="{Binding GroupTag}"/>
                    <GridViewColumn Header="Intune" Width="60" DisplayMemberBinding="{Binding IntuneFound}"/>
                    <GridViewColumn Header="Entra" Width="60" DisplayMemberBinding="{Binding EntraFound}"/>
                    <GridViewColumn Header="Intune Name" Width="150" DisplayMemberBinding="{Binding IntuneName}"/>
                    <GridViewColumn Header="Entra Name" Width="150" DisplayMemberBinding="{Binding EntraName}"/>
                </GridView>
            </ListView.View>
        </ListView>

        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button Name="OkBtn" Content="OK" Width="100" Padding="5" Margin="0,0,10,0" IsDefault="True" FontSize="14"/>
            <Button Name="CancelBtn" Content="Cancel" Width="100" Padding="5" IsCancel="True" FontSize="14"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $searchBox = $window.FindName("SearchBox")
    $searchPlaceholder = $window.FindName("SearchPlaceholder")
    $selectAllBtn = $window.FindName("SelectAllBtn")
    $clearAllBtn = $window.FindName("ClearAllBtn")
    $countLabel = $window.FindName("CountLabel")
    $listView = $window.FindName("DeviceList")
    $okBtn = $window.FindName("OkBtn")
    $cancelBtn = $window.FindName("CancelBtn")

    $listView.ItemsSource = $script:filteredList
    $countLabel.Text = "0 of $($script:deviceList.Count) selected"

    # Update count function
    $updateCount = {
        $selected = ($script:deviceList | Where-Object { $_.Selected }).Count
        $countLabel.Text = "$selected of $($script:deviceList.Count) selected"
    }

    # Search filter
    $searchBox.Add_TextChanged({
        $searchText = $searchBox.Text.ToLower()
        $searchPlaceholder.Visibility = if ($searchText) { "Collapsed" } else { "Visible" }

        $script:filteredList.Clear()
        foreach ($item in $script:deviceList) {
            if ($item.DisplayName.ToLower().Contains($searchText) -or
                $item.SerialNumber.ToLower().Contains($searchText) -or
                $item.Model.ToLower().Contains($searchText) -or
                $item.GroupTag.ToLower().Contains($searchText)) {
                $null = $script:filteredList.Add($item)
            }
        }
        $listView.Items.Refresh()
    })

    $selectAllBtn.Add_Click({
        foreach ($item in $script:filteredList) { $item.Selected = $true }
        $listView.Items.Refresh()
        & $updateCount
    })

    $clearAllBtn.Add_Click({
        foreach ($item in $script:filteredList) { $item.Selected = $false }
        $listView.Items.Refresh()
        & $updateCount
    })

    # Update count when checkbox changes
    $listView.AddHandler(
        [System.Windows.Controls.CheckBox]::CheckedEvent,
        [System.Windows.RoutedEventHandler]{ & $updateCount }
    )
    $listView.AddHandler(
        [System.Windows.Controls.CheckBox]::UncheckedEvent,
        [System.Windows.RoutedEventHandler]{ & $updateCount }
    )

    $script:dialogResult = $false
    $okBtn.Add_Click({
        $script:dialogResult = $true
        $window.Close()
    })

    $cancelBtn.Add_Click({
        $script:dialogResult = $false
        $window.Close()
    })

    $null = $window.ShowDialog()

    if ($script:dialogResult) {
        return ($script:deviceList | Where-Object { $_.Selected } | ForEach-Object { $_.Original })
    }
    return $null
}
