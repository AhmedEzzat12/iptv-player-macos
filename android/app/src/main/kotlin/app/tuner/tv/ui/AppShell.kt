package app.tuner.tv.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.tv.material3.DrawerValue
import androidx.tv.material3.Icon
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.NavigationDrawer
import androidx.tv.material3.NavigationDrawerItem
import androidx.tv.material3.NavigationDrawerScope
import androidx.tv.material3.Text
import androidx.tv.material3.rememberDrawerState
import app.tuner.tv.R

/**
 * The app's frame: a left drawer (collapsed to icons, expands when focused) and the selected section.
 * Back from a section moves focus to the drawer; Back on the drawer leaves the app (Google TV guidelines: no
 * confirmation). Each section's own back stack arrives with its screens (phase 5).
 */
@Composable
fun AppShell() {
    var selected by rememberSaveable { mutableStateOf(Section.launch) }
    var contentHasFocus by remember { mutableStateOf(false) }
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val itemFocus = remember { Section.entries.associateWith { FocusRequester() } }
    val contentFocus = remember { FocusRequester() }

    BackHandler(enabled = contentHasFocus) {
        itemFocus.getValue(selected).requestFocus()
    }

    NavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            Column(
                Modifier.fillMaxHeight().padding(vertical = 27.dp, horizontal = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Section.entries.filter { it != Section.Settings }.forEach { section ->
                    DrawerItem(section, selected, itemFocus.getValue(section)) { selected = it }
                }
                Spacer(Modifier.weight(1f))
                DrawerItem(Section.Settings, selected, itemFocus.getValue(Section.Settings)) { selected = it }
            }
        },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.background)
                .onFocusChanged { contentHasFocus = it.hasFocus }
                .padding(start = 48.dp, end = 48.dp, top = 27.dp, bottom = 27.dp),
        ) {
            SectionPlaceholder(selected, Modifier.focusRequester(contentFocus))
        }
    }

    LaunchedEffect(Unit) { contentFocus.requestFocus() }
}

@Composable
private fun NavigationDrawerScope.DrawerItem(
    section: Section,
    selected: Section,
    focusRequester: FocusRequester,
    onSelect: (Section) -> Unit,
) {
    NavigationDrawerItem(
        selected = section == selected,
        onClick = { onSelect(section) },
        leadingContent = { Icon(section.icon, contentDescription = null) },
        modifier = Modifier.focusRequester(focusRequester),
    ) {
        Text(stringResource(section.title))
    }
}

/** Stand-in for each section until its screen is built (phase 5). Focusable so Back and D-pad work end to end. */
@Composable
private fun SectionPlaceholder(section: Section, modifier: Modifier = Modifier) {
    Column(modifier.focusable(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(stringResource(section.title), style = MaterialTheme.typography.displaySmall)
        Text(stringResource(R.string.placeholder_coming), style = MaterialTheme.typography.bodyLarge)
    }
}
