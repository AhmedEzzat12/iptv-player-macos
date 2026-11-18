package app.tuner.tv.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.Text

/**
 * A modal panel in its own window. The old overlays were drawn inside the page, so the D-pad could leave them for the
 * cards underneath (or reach the sidebar), and every screen needed its own Back handling for them. A dialog window
 * keeps focus inside, takes Back itself (`onDismiss`), and gives focus back to the control that opened it on close.
 */
@Composable
fun TvDialog(onDismiss: () -> Unit, width: Dp = 560.dp, content: @Composable ColumnScope.() -> Unit) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.width(width).background(TunerColors.raised, RoundedCornerShape(26.dp)).padding(28.dp), content = content)
    }
}

/** A dialog's title and an optional line under it. */
@Composable
fun ColumnScope.DialogTitle(title: String, detail: String? = null) {
    Text(title, style = MaterialTheme.typography.headlineSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
    if (detail != null) {
        Spacer(Modifier.height(8.dp))
        Text(detail, style = MaterialTheme.typography.bodyMedium, color = TunerColors.secondary)
    }
    Spacer(Modifier.height(20.dp))
}

/** One action in a long-press menu. */
data class MenuAction(val title: String, val run: () -> Unit)

/** A full-width row in a menu: quiet until focused, then white (the tvOS context menu's rows). */
@Composable
fun MenuRow(title: String, onClick: () -> Unit, modifier: Modifier = Modifier, detail: String? = null) {
    Surface(
        onClick = onClick, modifier = modifier.fillMaxWidth().height(if (detail != null) 60.dp else 50.dp),
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(14.dp)),
        colors = ClickableSurfaceDefaults.colors(containerColor = Color.Transparent, contentColor = Color.White,
            focusedContainerColor = Color.White, focusedContentColor = TunerColors.onFocus),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1.02f),
    ) {
        Column(Modifier.padding(horizontal = 18.dp).fillMaxWidth().height(if (detail != null) 60.dp else 50.dp), verticalArrangement = Arrangement.Center) {
            Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (detail != null) Text(detail, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = androidx.tv.material3.LocalContentColor.current.copy(alpha = 0.65f))
        }
    }
}

/**
 * The long-press menu for a channel, category or title (the Apple apps' context menu): a title and a list of actions.
 * Picking an action closes the menu first; Back or Cancel closes it.
 */
@Composable
fun ItemMenu(title: String, actions: List<MenuAction>, onDismiss: () -> Unit) {
    TvDialog(onDismiss, width = 480.dp) {
        DialogTitle(title)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            actions.forEachIndexed { i, action ->
                MenuRow(action.title, onClick = { onDismiss(); action.run() }, modifier = Modifier.initialFocus(title, enabled = i == 0))
            }
            MenuRow("Cancel", onClick = onDismiss)
        }
    }
}

/** Asks before something that can't be undone (removing a playlist). Cancel has focus, so a stray OK is harmless. */
@Composable
fun ConfirmDialog(title: String, detail: String, confirm: String, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    TvDialog(onDismiss) {
        DialogTitle(title, detail)
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            PillButton(confirm, onClick = { onDismiss(); onConfirm() })
            PillButton("Cancel", onClick = onDismiss, modifier = Modifier.initialFocus(title))
        }
    }
}

/** Rename a channel or category; an empty name goes back to the provider's. */
@Composable
fun RenameDialog(title: String, current: String, original: String, onSave: (String?) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(current) }
    var focused by remember { mutableStateOf(false) }
    TvDialog(onDismiss, width = 620.dp) {
        DialogTitle(title, "Leave empty to use the provider's name, “$original”.")
        Box(Modifier.fillMaxWidth().background(if (focused) Color.White.copy(alpha = 0.2f) else Color.Black.copy(alpha = 0.3f), RoundedCornerShape(12.dp)).padding(14.dp),
            contentAlignment = Alignment.CenterStart) {
            BasicTextField(
                text, { text = it }, singleLine = true,
                textStyle = TextStyle(color = Color.White, fontSize = 22.sp),
                cursorBrush = SolidColor(TunerColors.accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onSave(text); onDismiss() }),
                modifier = Modifier.fillMaxWidth().initialFocus(title).onFocusChanged { focused = it.isFocused },
            )
        }
        Spacer(Modifier.height(22.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            PillButton("Save", onClick = { onSave(text); onDismiss() })
            PillButton("Cancel", onClick = onDismiss)
        }
    }
}
